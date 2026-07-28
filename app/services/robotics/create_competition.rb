require "set"

module Robotics
  class CreateCompetition
    MAX_TEAM_COUNT = 20

    Result = Data.define(:competition, :issued_pins)

    def self.call(attributes, team_count: 5)
      new(attributes, team_count: team_count).call
    end

    def initialize(attributes, team_count:)
      @attributes = attributes
      @team_count = Integer(team_count)
    end

    def call
      unless team_count.between?(1, MAX_TEAM_COUNT)
        raise ArgumentError, "team_count must be between 1 and #{MAX_TEAM_COUNT}"
      end

      competition = nil
      issued_pins = []

      RoboticsCompetition.transaction do
        competition = RoboticsCompetition.create!(attributes)
        fingerprints = Set.new

        team_count.times do |index|
          pin, fingerprint = unique_pin(competition, fingerprints)
          fingerprints << fingerprint
          team = competition.robotics_teams.create!(
            name: "Echipa #{index + 1}",
            position: index + 1,
            pin_digest: RoboticsTeam.pin_digest(pin),
            pin_fingerprint: fingerprint
          )
          team.robotics_time_entries.create!(
            robotics_competition: competition,
            kind: RoboticsTimeEntry::INITIAL_GRANT,
            amount_seconds: competition.team_allocation_seconds,
            reason: "Initial competition allocation"
          )
          issued_pins << {team: team, pin: pin}
        end
      end

      Result.new(competition: competition, issued_pins: issued_pins)
    end

    private

    attr_reader :attributes, :team_count

    def unique_pin(competition, fingerprints)
      loop do
        pin = RoboticsTeam.generate_pin
        fingerprint = RoboticsTeam.pin_fingerprint(competition.id, pin)
        return [pin, fingerprint] unless fingerprints.include?(fingerprint)
      end
    end
  end
end
