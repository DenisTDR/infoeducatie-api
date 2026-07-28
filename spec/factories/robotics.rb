FactoryBot.define do
  sequence :robotics_competition_name do |number|
    "Robotics competition #{number}"
  end

  sequence :robotics_team_name do |number|
    "Robot team #{number}"
  end

  sequence :robotics_team_position do |number|
    number
  end

  sequence :robotics_pin_number do |number|
    (10_000_000 + number).to_s
  end

  factory :robotics_competition do
    name { generate(:robotics_competition_name) }
    slug { name.parameterize }
    starts_at { 1.hour.ago }
    duration_seconds { 20.hours.to_i }
    team_allocation_seconds { 3.hours.to_i }
    turn_duration_seconds { 10.minutes.to_i }
    claim_window_seconds { 60 }
    turnover_seconds { 60 }
  end

  factory :robotics_team do
    association :robotics_competition
    name { generate(:robotics_team_name) }
    position { generate(:robotics_team_position) }

    transient do
      plaintext_pin { generate(:robotics_pin_number) }
      allocation_seconds { robotics_competition.team_allocation_seconds }
    end

    pin_digest { RoboticsTeam.pin_digest(plaintext_pin) }
    pin_fingerprint {
      RoboticsTeam.pin_fingerprint(robotics_competition.id, plaintext_pin)
    }

    after(:create) do |team, evaluator|
      team.robotics_time_entries.create!(
        robotics_competition: team.robotics_competition,
        kind: RoboticsTimeEntry::INITIAL_GRANT,
        amount_seconds: evaluator.allocation_seconds,
        reason: "Factory initial grant"
      )
    end
  end
end
