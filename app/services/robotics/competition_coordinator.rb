module Robotics
  class CompetitionCoordinator
    class << self
      def sync!(competition, now: Time.current)
        competition.with_lock do
          new(competition, now: now).synchronize!
        end
        competition.reload
      end

      def sync_if_needed!(competition, now: Time.current)
        coordinator = new(competition, now: now)
        return competition unless coordinator.synchronization_required?

        sync!(competition, now: now)
      end

      def set_readiness!(competition, team:, ready:, now: Time.current)
        competition.with_lock do
          coordinator = new(competition, now: now)
          coordinator.synchronize!
          coordinator.set_readiness!(team, ready)
          coordinator.synchronize!
        end
        competition.reload
      end

      def claim!(competition, team:, turn_id:, now: Time.current)
        competition.with_lock do
          coordinator = new(competition, now: now)
          coordinator.synchronize!
          coordinator.claim!(team, turn_id)
        end
        competition.reload
      end

      def pass!(competition, team:, turn_id:, now: Time.current)
        competition.with_lock do
          coordinator = new(competition, now: now)
          coordinator.synchronize!
          coordinator.pass!(team, turn_id)
          coordinator.synchronize!
        end
        competition.reload
      end

      def stop!(competition, team:, turn_id:, now: Time.current)
        competition.with_lock do
          coordinator = new(competition, now: now)
          coordinator.synchronize!
          coordinator.stop!(team, turn_id)
        end
        competition.reload
      end

      def force_stop!(turn, actor:, reason:, now: Time.current)
        competition = turn.robotics_competition
        competition.with_lock do
          coordinator = new(competition, now: now)
          coordinator.synchronize!
          coordinator.force_stop!(turn, actor: actor, reason: reason)
        end
        competition.reload
      end
    end

    def initialize(competition, now:)
      @competition = competition
      @now = now
    end

    def synchronize!
      if competition.ended?(at: now)
        close_competition!
        return
      end
      return unless competition.live?(at: now)

      loop do
        turn = current_turn
        break unless turn

        if turn.offered? && turn.robotics_team.balance_seconds <= 0
          turn.robotics_team.update!(ready: false)
          turn.update!(
            state: "withdrawn",
            ended_at: now,
            stop_reason: "time_exhausted"
          )
          next
        end

        if !turn.robotics_team.enabled? &&
            turn.state.in?(%w[offered active])
          turn.robotics_team.update!(ready: false)
          if turn.active?
            finalize_active!(
              turn,
              ended_at: now,
              reason: "team_suspended"
            )
          elsif turn.offered?
            turn.update!(
              state: "withdrawn",
              ended_at: now,
              stop_reason: "team_suspended"
            )
            turn.robotics_team.update!(ready: false)
          end
          next
        end

        case turn.state
        when "offered"
          break if turn.offer_expires_at > now

          expire_offer!(turn)
        when "active"
          break if turn.session_ends_at > now

          finalize_active!(
            turn,
            ended_at: turn.session_ends_at,
            reason: "turn_expired"
          )
        when "turnover"
          break if turn.turnover_ends_at > now

          turn.update!(state: "completed")
        end
      end

      allocate_next! unless current_turn
    end

    def synchronization_required?
      turn = competition.robotics_turns.live_lease.includes(:robotics_team).first

      if competition.ended?(at: now)
        return turn.present? ||
          competition.robotics_queue_entries.exists? ||
          competition.robotics_teams.where(ready: true).exists?
      end
      return false unless competition.live?(at: now)
      return competition.robotics_queue_entries.exists? unless turn
      return true unless turn.robotics_team.enabled?
      return true if turn.offered? && turn.robotics_team.balance_seconds <= 0

      case turn.state
      when "offered"
        turn.offer_expires_at <= now
      when "active"
        turn.session_ends_at <= now
      when "turnover"
        turn.turnover_ends_at <= now
      else
        false
      end
    end

    def set_readiness!(team, ready)
      reload_team!(team)
      ensure_team_belongs!(team)
      ensure_team_enabled!(team)

      if ready
        require_live_competition!
        if team.cooldown_until && team.cooldown_until > now
          raise TransitionError.new(
            "team_in_cooldown",
            "The team cannot rejoin until its cooldown ends."
          )
        end
        ensure_positive_balance!(team)
        team.update!(ready: true, cooldown_until: nil)
        enqueue_team!(team) unless team_holds_offer_or_session?(team)
      else
        team.update!(ready: false)
        team.robotics_queue_entry&.destroy!

        turn = current_turn
        if turn&.offered? && turn.robotics_team_id == team.id
          turn.update!(
            state: "withdrawn",
            ended_at: now,
            stop_reason: "readiness_withdrawn"
          )
        end
      end
    end

    def claim!(team, turn_id)
      reload_team!(team)
      ensure_team_belongs!(team)
      ensure_team_enabled!(team)
      require_live_competition!

      requested_turn = find_team_turn!(team, turn_id)
      return if requested_turn.started_at.present? &&
        requested_turn.state.in?(%w[active turnover completed])

      turn = current_turn
      unless turn&.offered? &&
          turn.id == requested_turn.id &&
          turn.robotics_team_id == team.id
        raise TransitionError.new(
          "offer_unavailable",
          "There is no claimable offer for this team."
        )
      end
      if turn.offer_expires_at <= now
        raise TransitionError.new(
          "offer_expired",
          "The claim window has expired."
        )
      end

      balance = team.balance_seconds
      competition_remaining = (competition.ends_at - now).floor
      reserved_seconds = [
        competition.turn_duration_seconds,
        balance,
        competition_remaining
      ].min
      if reserved_seconds <= 0
        raise TransitionError.new(
          "time_exhausted",
          "The team has no testing time remaining."
        )
      end

      turn.update!(
        state: "active",
        started_at: now,
        session_ends_at: now + reserved_seconds.seconds,
        reserved_seconds: reserved_seconds
      )
    end

    def pass!(team, turn_id)
      reload_team!(team)
      ensure_team_belongs!(team)
      ensure_team_enabled!(team)
      require_live_competition!

      requested_turn = find_team_turn!(team, turn_id)
      return if requested_turn.state == "passed"

      turn = current_turn
      unless turn&.offered? &&
          turn.id == requested_turn.id &&
          turn.robotics_team_id == team.id
        raise TransitionError.new(
          "offer_unavailable",
          "There is no offer for this team to pass."
        )
      end

      turn.update!(
        state: "passed",
        ended_at: now,
        stop_reason: "team_passed"
      )
      team.update!(ready: true, cooldown_until: nil)
      enqueue_team!(team)
    end

    def stop!(team, turn_id)
      reload_team!(team)
      ensure_team_belongs!(team)
      requested_turn = find_team_turn!(team, turn_id)
      return if requested_turn.started_at.present? && requested_turn.ended_at

      turn = current_turn
      if turn&.active? &&
          turn.id == requested_turn.id &&
          turn.robotics_team_id == team.id
        finalize_active!(turn, ended_at: now, reason: "team_stopped")
        return
      end

      raise TransitionError.new(
        "no_active_turn",
        "This team does not have an active testing turn."
      )
    end

    def force_stop!(turn, actor:, reason:)
      turn = competition.robotics_turns.lock.find(turn.id)
      unless turn.active?
        raise TransitionError.new(
          "turn_not_active",
          "Only an active testing turn can be force-stopped."
        )
      end
      unless actor&.admin?
        raise TransitionError.new(
          "administrator_required",
          "An administrator is required.",
          status: :forbidden
        )
      end
      if reason.to_s.strip.blank?
        raise TransitionError.new(
          "reason_required",
          "A reason is required.",
          status: :unprocessable_content
        )
      end

      finalize_active!(
        turn,
        ended_at: now,
        reason: reason.to_s.strip,
        stopped_by: actor
      )
    end

    private

    attr_reader :competition, :now

    def current_turn
      competition.robotics_turns.live_lease.lock.order(:id).first
    end

    def close_competition!
      competition.robotics_queue_entries.delete_all
      competition.robotics_teams.where(ready: true).update_all(
        ready: false,
        updated_at: now
      )
      turn = current_turn
      return unless turn

      case turn.state
      when "active"
        finalize_active!(
          turn,
          ended_at: [turn.session_ends_at, competition.ends_at].min,
          reason: "competition_ended",
          turnover: false
        )
      when "offered"
        turn.update!(
          state: "expired",
          ended_at: competition.ends_at,
          stop_reason: "competition_ended"
        )
      when "turnover"
        turn.update!(state: "completed")
      end
    end

    def expire_offer!(turn)
      turn.update!(
        state: "expired",
        ended_at: turn.offer_expires_at,
        stop_reason: "claim_window_expired"
      )
      team = turn.robotics_team
      team.update!(
        ready: false,
        cooldown_until: turn.offer_expires_at +
          competition.turn_duration_seconds.seconds
      )
      team.robotics_queue_entry&.destroy!
    end

    def finalize_active!(
      turn,
      ended_at:,
      reason:,
      stopped_by: nil,
      turnover: true
    )
      return if turn.robotics_time_entry

      effective_end = [
        ended_at,
        turn.session_ends_at,
        competition.ends_at
      ].compact.min
      elapsed = (effective_end - turn.started_at).ceil
      charged_seconds = [
        [[elapsed, 1].max, turn.reserved_seconds].min,
        0
      ].max

      RoboticsTimeEntry.create!(
        robotics_competition: competition,
        robotics_team: turn.robotics_team,
        robotics_turn: turn,
        kind: RoboticsTimeEntry::SESSION_USAGE,
        amount_seconds: -charged_seconds,
        reason: "Testing turn ##{turn.sequence_number}: #{reason}"
      )

      if turnover
        turnover_ends_at = [
          effective_end + competition.turnover_seconds.seconds,
          competition.ends_at
        ].min
        turn.update!(
          state: "turnover",
          ended_at: effective_end,
          turnover_ends_at: turnover_ends_at,
          charged_seconds: charged_seconds,
          stop_reason: reason,
          stopped_by: stopped_by
        )
      else
        turn.update!(
          state: "completed",
          ended_at: effective_end,
          charged_seconds: charged_seconds,
          stop_reason: reason,
          stopped_by: stopped_by
        )
      end

      team = turn.robotics_team
      if turnover && team.ready? && team.balance_seconds.positive?
        enqueue_team!(team)
      else
        team.update!(ready: false) unless team.balance_seconds.positive?
      end
    end

    def allocate_next!
      return unless competition.live?(at: now)
      return if current_turn

      entry = next_valid_queue_entry
      return unless entry

      expires_at = [
        now + competition.claim_window_seconds.seconds,
        competition.ends_at
      ].min
      return unless expires_at > now

      competition.robotics_turns.create!(
        robotics_team: entry.robotics_team,
        sequence_number: competition.next_turn_sequence!,
        state: "offered",
        offered_at: now,
        offer_expires_at: expires_at
      )
      entry.destroy!
    rescue ActiveRecord::RecordNotUnique
      # The partial unique index is the last line of defense if a caller ever
      # bypasses the common competition-row lock.
      raise TransitionError.new(
        "arena_busy",
        "The testing arena is already reserved."
      )
    end

    def next_valid_queue_entry
      competition.robotics_queue_entries
        .includes(:robotics_team)
        .lock
        .order(:sequence_number)
        .each do |entry|
          team = entry.robotics_team
          valid = team.ready? &&
            team.enabled? &&
            !(team.cooldown_until && team.cooldown_until > now) &&
            team.balance_seconds.positive?
          return entry if valid

          team.update!(ready: false)
          entry.destroy!
        end
      nil
    end

    def enqueue_team!(team)
      return if team.robotics_queue_entry

      competition.robotics_queue_entries.create!(
        robotics_team: team,
        sequence_number: competition.next_queue_sequence!,
        requested_at: now
      )
    end

    def team_holds_offer_or_session?(team)
      turn = current_turn
      turn && turn.robotics_team_id == team.id &&
        turn.state.in?(%w[offered active])
    end

    def reload_team!(team)
      team.reload
    end

    def ensure_team_belongs!(team)
      return if team.robotics_competition_id == competition.id

      raise TransitionError.new(
        "team_not_found",
        "The team does not belong to this competition.",
        status: :not_found
      )
    end

    def find_team_turn!(team, turn_id)
      turn = competition.robotics_turns.find_by(
        id: turn_id,
        robotics_team_id: team.id
      )
      return turn if turn

      raise TransitionError.new(
        "turn_mismatch",
        "The requested turn does not belong to this team."
      )
    end

    def require_live_competition!
      return if competition.live?(at: now)

      raise TransitionError.new(
        "competition_not_live",
        "Queue actions are available only while the competition is live."
      )
    end

    def ensure_team_enabled!(team)
      return if team.enabled?

      raise TransitionError.new(
        "team_suspended",
        "This team has been suspended by an administrator.",
        status: :forbidden
      )
    end

    def ensure_positive_balance!(team)
      return if team.balance_seconds.positive?

      team.update!(ready: false)
      raise TransitionError.new(
        "time_exhausted",
        "The team has no testing time remaining."
      )
    end
  end
end
