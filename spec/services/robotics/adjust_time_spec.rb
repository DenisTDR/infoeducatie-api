require "rails_helper"

RSpec.describe Robotics::AdjustTime do
  let(:admin) { create(:admin_user) }
  let(:team) { create(:robotics_team, allocation_seconds: 3.hours) }

  it "creates an immutable signed adjustment" do
    entry = described_class.call(
      team: team,
      amount_seconds: 15.minutes,
      reason: "Technical delay compensation",
      actor: admin
    )

    expect(entry).to have_attributes(
      kind: RoboticsTimeEntry::ADMIN_ADJUSTMENT,
      amount_seconds: 15.minutes.to_i,
      reason: "Technical delay compensation",
      actor: admin
    )
    expect(team.balance_seconds).to eq(195.minutes.to_i)
  end

  it "rejects deductions that exceed the remaining bank" do
    expect {
      described_class.call(
        team: team,
        amount_seconds: -181.minutes,
        reason: "Invalid deduction",
        actor: admin
      )
    }.to raise_error(
      Robotics::TransitionError,
      "The deduction exceeds the team's remaining time."
    )
  end

  it "does not let an ordinary user create admin ledger entries" do
    expect {
      described_class.call(
        team: team,
        amount_seconds: 5.minutes,
        reason: "Unauthorized",
        actor: create(:confirmed_user)
      )
    }.to raise_error(Robotics::TransitionError, "An administrator is required.")
  end

  it "withdraws a zero-balance offer and immediately offers the next team" do
    competition = team.robotics_competition
    second_team = create(
      :robotics_team,
      robotics_competition: competition,
      allocation_seconds: 3.hours
    )
    now = Time.current.change(usec: 0)
    Robotics::CompetitionCoordinator.set_readiness!(
      competition,
      team: team,
      ready: true,
      now: now
    )
    Robotics::CompetitionCoordinator.set_readiness!(
      competition,
      team: second_team,
      ready: true,
      now: now + 1.second
    )
    old_offer = competition.robotics_turns.live_lease.first

    described_class.call(
      team: team,
      amount_seconds: -3.hours,
      reason: "Allocation revoked",
      actor: admin,
      now: now + 2.seconds
    )

    expect(old_offer.reload).to have_attributes(
      state: "withdrawn",
      stop_reason: "time_exhausted"
    )
    expect(team.reload).not_to be_ready
    next_offer = competition.robotics_turns.live_lease.first
    expect(next_offer.robotics_team).to eq(second_team)

    payload = Robotics::CompetitionStateSerializer.new(
      competition.reload,
      viewer: team
    ).as_json
    expect(payload.dig(:viewer, :capabilities, :claim)).to be(false)
  end
end
