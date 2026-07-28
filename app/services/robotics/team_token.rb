module Robotics
  class TeamToken
    PURPOSE = "robotics-team-access"
    CIPHER = "aes-256-gcm"

    class << self
      def issue(team)
        encryptor.encrypt_and_sign(
          {
            team_id: team.id,
            authentication_version: team.authentication_version
          },
          expires_at: team.robotics_competition.ends_at + 1.day,
          purpose: PURPOSE
        )
      end

      def authenticate(token, competition:)
        payload = encryptor.decrypt_and_verify(token.to_s, purpose: PURPOSE)
        team_id = payload["team_id"] || payload[:team_id]
        version = payload["authentication_version"] ||
          payload[:authentication_version]
        team = competition.robotics_teams.find_by(id: team_id)
        return unless team
        return unless team.enabled?
        return unless ActiveSupport::SecurityUtils.secure_compare(
          team.authentication_version.to_s,
          version.to_s
        )

        team
      rescue ActiveSupport::MessageEncryptor::InvalidMessage
        nil
      end

      private

      def encryptor
        @encryptor ||= ActiveSupport::MessageEncryptor.new(
          Rails.application.key_generator.generate_key(
            "robotics-team-access-token",
            ActiveSupport::MessageEncryptor.key_len(CIPHER)
          ),
          cipher: CIPHER,
          serializer: JSON
        )
      end
    end
  end
end
