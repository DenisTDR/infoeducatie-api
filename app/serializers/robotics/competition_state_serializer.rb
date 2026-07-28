module Robotics
  class CompetitionStateSerializer
    def initialize(competition, viewer: nil, now: Time.current)
      @competition = competition
      @viewer = viewer
      @now = now
      @teams = competition.robotics_teams.order(:position, :id).to_a
      @turn = competition.robotics_turns.live_lease.includes(:robotics_team).first
      @queue_entries = competition.robotics_queue_entries
        .includes(:robotics_team)
        .order(:sequence_number)
        .to_a
      @queue_positions = queue_entries.each_with_index.to_h do |entry, index|
        [entry.robotics_team_id, index + 1]
      end
      @ledger = competition.robotics_time_entries
        .group(:robotics_team_id, :kind)
        .sum(:amount_seconds)
      @completed_turns = competition.robotics_turns
        .where.not(started_at: nil)
        .where.not(state: "active")
        .group(:robotics_team_id)
        .count
    end

    def as_json(*)
      {
        server_now: iso_time(now),
        competition: competition_payload,
        arena: arena_payload,
        queue: queue_payload,
        teams: teams.map { |team| team_payload(team) },
        viewer: viewer_payload
      }
    end

    private

    attr_reader :competition,
      :viewer,
      :now,
      :teams,
      :turn,
      :queue_entries,
      :queue_positions,
      :ledger,
      :completed_turns

    def competition_payload
      {
        id: competition.id,
        slug: competition.slug,
        name: competition.name,
        status: competition.status(at: now),
        starts_at: iso_time(competition.starts_at),
        ends_at: iso_time(competition.ends_at),
        duration_seconds: competition.duration_seconds,
        turn_duration_seconds: competition.turn_duration_seconds,
        claim_window_seconds: competition.claim_window_seconds,
        turnover_seconds: competition.turnover_seconds
      }
    end

    def arena_payload
      {
        status: arena_status,
        turn_id: turn&.id,
        team_id: turn&.robotics_team_id,
        team_name: turn&.robotics_team&.name,
        offer_expires_at: turn&.offered? ? iso_time(turn.offer_expires_at) : nil,
        session_started_at: turn&.started_at ? iso_time(turn.started_at) : nil,
        session_ends_at: turn&.session_ends_at ? iso_time(turn.session_ends_at) : nil,
        available_at: iso_time(arena_available_at)
      }
    end

    def arena_status
      competition_status = competition.status(at: now)
      return "scheduled" if competition_status == "scheduled"
      return "closed" if competition_status == "ended"

      turn&.state || "available"
    end

    def arena_available_at
      case arena_status
      when "scheduled"
        competition.starts_at
      when "available"
        now
      when "offered"
        turn.offer_expires_at
      when "active"
        [
          turn.session_ends_at + competition.turnover_seconds.seconds,
          competition.ends_at
        ].min
      when "turnover"
        turn.turnover_ends_at
      end
    end

    def queue_payload
      queue_entries.each_with_index.map do |entry, index|
        {
          team_id: entry.robotics_team_id,
          team_name: entry.robotics_team.name,
          position: index + 1,
          requested_at: iso_time(entry.requested_at)
        }
      end
    end

    def team_payload(team)
      allocated = allocated_seconds_for(team)
      used = used_seconds_for(team)
      remaining = [allocated - used, 0].max
      queue_position = queue_positions[team.id]

      {
        id: team.id,
        name: team.name,
        position: team.position,
        status: team_status(
          team,
          remaining: remaining,
          queue_position: queue_position
        ),
        allocated_seconds: allocated,
        used_seconds: used,
        remaining_seconds: remaining,
        turns_completed: completed_turns.fetch(team.id, 0),
        queue_position: queue_position,
        ready: team.ready?,
        cooldown_until: iso_time(team.cooldown_until)
      }
    end

    def allocated_seconds_for(team)
      RoboticsTimeEntry::KINDS
        .reject { |kind| kind == RoboticsTimeEntry::SESSION_USAGE }
        .sum { |kind| ledger.fetch([team.id, kind], 0) }
    end

    def used_seconds_for(team)
      finalized = -ledger.fetch(
        [team.id, RoboticsTimeEntry::SESSION_USAGE],
        0
      )
      return finalized unless turn&.active? && turn.robotics_team_id == team.id

      effective_now = [now, turn.session_ends_at].min
      live_elapsed = (effective_now - turn.started_at).ceil
      finalized + [[live_elapsed, 0].max, turn.reserved_seconds].min
    end

    def team_status(team, remaining:, queue_position:)
      return "inactive" unless team.enabled?
      return "exhausted" unless remaining.positive?
      return "active" if turn&.active? && turn.robotics_team_id == team.id
      return "offered" if turn&.offered? && turn.robotics_team_id == team.id
      return "queued" if queue_position
      return "cooldown" if team.cooldown_until && team.cooldown_until > now
      return "available" if team.ready?

      "inactive"
    end

    def viewer_payload
      return nil unless viewer

      remaining = allocated_seconds_for(viewer) - used_seconds_for(viewer)
      owns_offer = turn&.offered? && turn.robotics_team_id == viewer.id
      owns_session = turn&.active? && turn.robotics_team_id == viewer.id
      live = competition.live?(at: now)
      cooldown = viewer.cooldown_until && viewer.cooldown_until > now
      enabled = viewer.enabled?

      {
        team_id: viewer.id,
        ready: viewer.ready?,
        capabilities: {
          join_queue: live &&
            enabled &&
            !viewer.ready? &&
            !cooldown &&
            remaining.positive? &&
            !owns_offer &&
            !owns_session,
          leave_queue: live && enabled && viewer.ready?,
          claim: live && enabled && remaining.positive? && !!owns_offer,
          pass: live && enabled && !!owns_offer,
          stop: live && enabled && !!owns_session
        }
      }
    end

    def iso_time(value)
      value&.iso8601(3)
    end
  end
end
