module Robotics
  class AdjustTime
    def self.call(team:, amount_seconds:, reason:, actor:, now: Time.current)
      new(
        team: team,
        amount_seconds: amount_seconds,
        reason: reason,
        actor: actor,
        now: now
      ).call
    end

    def initialize(team:, amount_seconds:, reason:, actor:, now:)
      @team = team
      @competition = team.robotics_competition
      @amount_seconds = Integer(amount_seconds)
      @reason = reason.to_s.strip
      @actor = actor
      @now = now
    end

    def call
      raise_transition("amount_required", "The adjustment cannot be zero.") if amount_seconds.zero?
      raise_transition("reason_required", "A reason is required.") if reason.blank?
      unless actor&.admin?
        raise TransitionError.new(
          "administrator_required",
          "An administrator is required.",
          status: :forbidden
        )
      end

      entry = nil
      competition.with_lock do
        coordinator = CompetitionCoordinator.new(competition, now: now)
        coordinator.synchronize!
        team.reload

        resulting_balance = team.balance_seconds + amount_seconds
        if resulting_balance.negative?
          raise_transition(
            "insufficient_balance",
            "The deduction exceeds the team's remaining time."
          )
        end

        active_turn = competition.robotics_turns
          .live_lease
          .find_by(state: "active", robotics_team_id: team.id)
        if active_turn && resulting_balance < active_turn.reserved_seconds
          raise_transition(
            "active_reservation_conflict",
            "The deduction would cut into the team's active reservation."
          )
        end

        entry = RoboticsTimeEntry.create!(
          robotics_competition: competition,
          robotics_team: team,
          kind: RoboticsTimeEntry::ADMIN_ADJUSTMENT,
          amount_seconds: amount_seconds,
          reason: reason,
          actor: actor
        )
        coordinator.synchronize!
      end
      entry
    end

    private

    attr_reader :team,
      :competition,
      :amount_seconds,
      :reason,
      :actor,
      :now

    def raise_transition(code, message)
      raise TransitionError.new(
        code,
        message,
        status: :unprocessable_content
      )
    end
  end
end
