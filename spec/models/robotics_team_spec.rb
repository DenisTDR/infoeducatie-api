require "rails_helper"

RSpec.describe RoboticsTeam, type: :model do
  it "authenticates a generated PIN without storing the plaintext" do
    competition = create(:robotics_competition)
    team = create(
      :robotics_team,
      robotics_competition: competition,
      plaintext_pin: "87654321"
    )

    expect(team.attributes.values).not_to include("87654321")
    expect(described_class.authenticate_pin(competition, "87654321")).to eq(team)
    expect(described_class.authenticate_pin(competition, "00000000")).to be_nil
  end

  it "rotates the PIN and invalidates existing signed tokens" do
    team = create(:robotics_team)
    old_token = Robotics::TeamToken.issue(team)

    new_pin = team.rotate_pin!

    expect(new_pin).to match(/\A\d{8}\z/)
    expect(
      Robotics::TeamToken.authenticate(
        old_token,
        competition: team.robotics_competition
      )
    ).to be_nil
    expect(
      described_class.authenticate_pin(team.robotics_competition, new_pin)
    ).to eq(team)
  end

  it "uses immutable ledger entries for allocated, used, and remaining time" do
    team = create(:robotics_team, allocation_seconds: 3.hours)
    turn = team.robotics_turns.create!(
      robotics_competition: team.robotics_competition,
      sequence_number: 1,
      state: "completed",
      offered_at: 12.minutes.ago,
      offer_expires_at: 11.minutes.ago,
      started_at: 10.minutes.ago,
      session_ends_at: Time.current,
      ended_at: Time.current,
      reserved_seconds: 10.minutes,
      charged_seconds: 10.minutes
    )
    entry = team.robotics_time_entries.create!(
      robotics_competition: team.robotics_competition,
      robotics_turn: turn,
      kind: RoboticsTimeEntry::SESSION_USAGE,
      amount_seconds: -10.minutes,
      reason: "Test usage"
    )

    expect(team.allocated_seconds).to eq(3.hours)
    expect(team.used_seconds).to eq(10.minutes)
    expect(team.balance_seconds).to eq(170.minutes)
    expect { entry.update!(reason: "Rewritten") }
      .to raise_error(ActiveRecord::ReadOnlyRecord)
  end
end
