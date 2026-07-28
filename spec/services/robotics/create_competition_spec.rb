require "rails_helper"

RSpec.describe Robotics::CreateCompetition do
  it "atomically creates five teams, one-time PINs, and three-hour grants" do
    result = described_class.call(
      {
        name: "Drone testing 2026",
        slug: "drone-testing-2026",
        starts_at: 1.day.from_now,
        duration_seconds: 20.hours,
        team_allocation_seconds: 3.hours,
        turn_duration_seconds: 10.minutes,
        claim_window_seconds: 60,
        turnover_seconds: 60
      },
      team_count: 5
    )

    expect(result.competition).to be_persisted
    expect(result.issued_pins.length).to eq(5)
    expect(result.issued_pins.pluck(:pin)).to all(match(/\A\d{8}\z/))
    expect(result.competition.robotics_teams.order(:position).pluck(:name))
      .to eq(["Echipa 1", "Echipa 2", "Echipa 3", "Echipa 4", "Echipa 5"])
    expect(
      result.competition.robotics_time_entries
        .where(kind: RoboticsTimeEntry::INITIAL_GRANT)
        .pluck(:amount_seconds)
    ).to contain_exactly(*Array.new(5, 3.hours.to_i))
  end
end
