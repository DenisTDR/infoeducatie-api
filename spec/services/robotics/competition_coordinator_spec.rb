require "rails_helper"

RSpec.describe Robotics::CompetitionCoordinator do
  let(:starts_at) { Time.zone.parse("2026-07-29 08:00:00") }
  let(:competition) do
    create(
      :robotics_competition,
      starts_at: starts_at,
      duration_seconds: 20.hours,
      turn_duration_seconds: 10.minutes,
      claim_window_seconds: 60,
      turnover_seconds: 60
    )
  end
  let!(:first_team) do
    create(
      :robotics_team,
      robotics_competition: competition,
      name: "Alpha",
      position: 1,
      plaintext_pin: "11111111"
    )
  end
  let!(:second_team) do
    create(
      :robotics_team,
      robotics_competition: competition,
      name: "Beta",
      position: 2,
      plaintext_pin: "22222222"
    )
  end

  it "offers the FIFO head, passes it to the tail, and never accumulates turns" do
    now = starts_at + 1.hour
    described_class.set_readiness!(
      competition,
      team: first_team,
      ready: true,
      now: now
    )
    described_class.set_readiness!(
      competition,
      team: second_team,
      ready: true,
      now: now + 1.second
    )

    offer = competition.robotics_turns.live_lease.first
    expect(offer.robotics_team).to eq(first_team)
    expect(offer.offer_expires_at - offer.offered_at).to eq(60)

    described_class.pass!(
      competition,
      team: first_team,
      turn_id: offer.id,
      now: now + 2.seconds
    )

    next_offer = competition.robotics_turns.live_lease.first
    expect(next_offer.robotics_team).to eq(second_team)
    expect(
      competition.robotics_queue_entries.order(:sequence_number)
        .pluck(:robotics_team_id)
    ).to eq([first_team.id])

    described_class.claim!(
      competition,
      team: second_team,
      turn_id: next_offer.id,
      now: now + 3.seconds
    )
    expect(next_offer.reload.reserved_seconds).to eq(10.minutes)
  end

  it "charges actual elapsed seconds on early stop and preserves the balance" do
    now = starts_at + 1.hour
    described_class.set_readiness!(
      competition,
      team: first_team,
      ready: true,
      now: now
    )
    turn_id = competition.robotics_turns.live_lease.pick(:id)
    described_class.claim!(
      competition,
      team: first_team,
      turn_id: turn_id,
      now: now + 1.second
    )
    described_class.stop!(
      competition,
      team: first_team,
      turn_id: turn_id,
      now: now + 4.minutes + 1.second
    )

    turn = competition.robotics_turns.order(:sequence_number).last
    expect(turn).to have_attributes(
      state: "turnover",
      charged_seconds: 4.minutes
    )
    expect(first_team.balance_seconds).to eq(3.hours - 4.minutes)
    expect(
      competition.robotics_queue_entries.find_by(robotics_team: first_team)
    ).to be_present
  end

  it "expires unclaimed offers without charging time and applies cooldown" do
    now = starts_at + 1.hour
    described_class.set_readiness!(
      competition,
      team: first_team,
      ready: true,
      now: now
    )
    described_class.sync!(competition, now: now + 61.seconds)

    turn = competition.robotics_turns.order(:sequence_number).last
    expect(turn.state).to eq("expired")
    expect(first_team.reload).not_to be_ready
    expect(first_team.cooldown_until).to eq(now + 60.seconds + 10.minutes)
    expect(first_team.balance_seconds).to eq(3.hours)
  end

  it "keeps ordinary public-state synchronization on the read-only fast path" do
    now = starts_at + 1.hour

    expect(competition).not_to receive(:with_lock)
    expect(
      described_class.sync_if_needed!(competition, now: now)
    ).to eq(competition)
  end

  it "truncates the final turn at the competition end" do
    now = competition.ends_at - 3.minutes
    described_class.set_readiness!(
      competition,
      team: first_team,
      ready: true,
      now: now
    )
    turn_id = competition.robotics_turns.live_lease.pick(:id)
    described_class.claim!(
      competition,
      team: first_team,
      turn_id: turn_id,
      now: now + 1.second
    )

    active = competition.robotics_turns.live_lease.first
    expect(active.session_ends_at).to eq(competition.ends_at)

    described_class.sync!(competition, now: competition.ends_at)
    expect(active.reload.state).to eq("completed")
    expect(active.charged_seconds).to eq(3.minutes - 1.second)
  end

  it "relies on a database unique index as well as the competition lock" do
    first_turn = competition.robotics_turns.create!(
      robotics_team: first_team,
      sequence_number: 1,
      state: "offered",
      offered_at: starts_at,
      offer_expires_at: starts_at + 60.seconds
    )

    expect {
      competition.robotics_turns.create!(
        robotics_team: second_team,
        sequence_number: 2,
        state: "offered",
        offered_at: starts_at,
        offer_expires_at: starts_at + 60.seconds
      )
    }.to raise_error(ActiveRecord::RecordNotUnique)
    expect(first_turn).to be_persisted
  end

  it "safely stops a turn when an administrator suspends its team" do
    now = starts_at + 1.hour
    described_class.set_readiness!(
      competition,
      team: first_team,
      ready: true,
      now: now
    )
    turn_id = competition.robotics_turns.live_lease.pick(:id)
    described_class.claim!(
      competition,
      team: first_team,
      turn_id: turn_id,
      now: now + 1.second
    )
    first_team.update!(enabled: false)

    described_class.sync!(competition, now: now + 2.seconds)

    turn = competition.robotics_turns.order(:sequence_number).last
    expect(turn).to have_attributes(
      state: "turnover",
      stop_reason: "team_suspended",
      charged_seconds: 1
    )
    expect(first_team.reload).not_to be_ready
  end

  it "serializes concurrent claim attempts through the competition row",
    :concurrent do
    now = starts_at + 1.hour
    described_class.set_readiness!(
      competition,
      team: first_team,
      ready: true,
      now: now
    )
    turn_id = competition.robotics_turns.live_lease.pick(:id)

    ready_threads = Queue.new
    start_threads = Queue.new
    results = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          local_competition = RoboticsCompetition.find(competition.id)
          local_team = RoboticsTeam.find(first_team.id)
          ready_threads << true
          start_threads.pop

          begin
            described_class.claim!(
              local_competition,
              team: local_team,
              turn_id: turn_id,
              now: now + 1.second
            )
            results << :claimed
          rescue Robotics::TransitionError => error
            results << error.code
          end
        end
      end
    end

    2.times { ready_threads.pop }
    2.times { start_threads << true }
    threads.each(&:join)

    expect(2.times.map { results.pop }).to contain_exactly(:claimed, :claimed)
    expect(
      competition.robotics_turns.where(state: "active").count
    ).to eq(1)
  end

  it "does not let a delayed stop for an old turn stop a later active turn" do
    now = starts_at + 1.hour
    described_class.set_readiness!(
      competition,
      team: first_team,
      ready: true,
      now: now
    )
    old_turn = competition.robotics_turns.live_lease.first
    described_class.claim!(
      competition,
      team: first_team,
      turn_id: old_turn.id,
      now: now + 1.second
    )
    described_class.stop!(
      competition,
      team: first_team,
      turn_id: old_turn.id,
      now: now + 2.seconds
    )

    later = now + competition.turnover_seconds.seconds + 3.seconds
    described_class.sync!(competition, now: later)
    new_turn = competition.robotics_turns.live_lease.first
    described_class.claim!(
      competition,
      team: first_team,
      turn_id: new_turn.id,
      now: later + 1.second
    )

    expect {
      described_class.stop!(
        competition,
        team: first_team,
        turn_id: old_turn.id,
        now: later + 2.seconds
      )
    }.not_to change { new_turn.reload.state }
    expect(new_turn.reload).to be_active
  end

  it "rejects a turn identifier that belongs to another team" do
    now = starts_at + 1.hour
    described_class.set_readiness!(
      competition,
      team: first_team,
      ready: true,
      now: now
    )
    turn = competition.robotics_turns.live_lease.first

    expect {
      described_class.claim!(
        competition,
        team: second_team,
        turn_id: turn.id,
        now: now + 1.second
      )
    }.to raise_error(Robotics::TransitionError) { |error|
      expect(error.code).to eq("turn_mismatch")
    }
  end
end
