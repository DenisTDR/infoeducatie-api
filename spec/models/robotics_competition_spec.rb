require "rails_helper"

RSpec.describe RoboticsCompetition, type: :model do
  it "generates a bounded slug from a Romanian competition name" do
    competition = build(
      :robotics_competition,
      name: ("Competiție românească pentru drone " * 3).strip.b,
      slug: ""
    )

    expect(competition).to be_valid
    expect(competition.slug).to start_with("competitie-romaneasca-pentru-drone")
    expect(competition.slug.length).to be <= 80
    expect(competition.slug).not_to end_with("-")
  end

  it "derives scheduled, live, and ended states from authoritative timestamps" do
    starts_at = Time.zone.parse("2026-07-29 08:00")
    competition = build(
      :robotics_competition,
      starts_at: starts_at,
      duration_seconds: 20.hours
    )

    expect(competition.status(at: starts_at - 1.second)).to eq("scheduled")
    expect(competition.status(at: starts_at)).to eq("live")
    expect(competition.status(at: starts_at + 20.hours)).to eq("ended")
    expect(competition.ends_at).to eq(starts_at + 20.hours)
  end

  it "validates that a turn fits inside the competition" do
    competition = build(
      :robotics_competition,
      duration_seconds: 5.minutes,
      turn_duration_seconds: 10.minutes
    )

    expect(competition).not_to be_valid
    expect(competition.errors[:turn_duration_seconds]).to be_present
  end

  it "allows scheduling changes only before the competition and turn history" do
    competition = create(
      :robotics_competition,
      starts_at: 1.day.from_now
    )

    expect(
      competition.update(
        starts_at: 2.days.from_now,
        duration_seconds: 21.hours,
        turn_duration_seconds: 12.minutes,
        claim_window_seconds: 90,
        turnover_seconds: 75
      )
    ).to be(true)
  end

  it "locks scheduling once the competition has started" do
    competition = create(
      :robotics_competition,
      starts_at: 1.hour.ago
    )

    expect(competition.update(duration_seconds: 21.hours)).to be(false)
    expect(competition.errors[:base]).to include(
      "Competition timing cannot change after it starts or has turn history"
    )
  end

  it "locks scheduling when any turn history exists before the start" do
    competition = create(
      :robotics_competition,
      starts_at: 1.day.from_now
    )
    team = create(:robotics_team, robotics_competition: competition)
    competition.robotics_turns.create!(
      robotics_team: team,
      sequence_number: 1,
      state: "passed",
      offered_at: Time.current,
      offer_expires_at: 1.minute.from_now,
      ended_at: Time.current,
      stop_reason: "test_history"
    )

    expect(competition.update(starts_at: 2.days.from_now)).to be(false)
    expect(competition.errors[:base]).to be_present
  end

  it "locks the default team allocation after grants have been issued" do
    competition = create(
      :robotics_competition,
      starts_at: 1.day.from_now
    )
    create(:robotics_team, robotics_competition: competition)

    expect(
      competition.update(team_allocation_seconds: 4.hours)
    ).to be(false)
    expect(competition.errors[:team_allocation_seconds]).to include(
      "cannot change after teams receive their initial grants"
    )
  end
end
