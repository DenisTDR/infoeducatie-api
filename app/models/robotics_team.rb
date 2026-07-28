require "bcrypt"

class RoboticsTeam < ActiveRecord::Base
  PIN_LENGTH = 8

  belongs_to :robotics_competition, inverse_of: :robotics_teams
  has_one :robotics_queue_entry, dependent: :destroy, inverse_of: :robotics_team
  has_many :robotics_turns, dependent: :restrict_with_error, inverse_of: :robotics_team
  has_many :robotics_time_entries,
    dependent: :restrict_with_error,
    inverse_of: :robotics_team

  validates :robotics_competition, presence: true
  validates :name,
    presence: true,
    length: {maximum: 100},
    uniqueness: {scope: :robotics_competition_id}
  validates :position,
    numericality: {only_integer: true, greater_than: 0},
    uniqueness: {scope: :robotics_competition_id}
  validates :pin_digest, :pin_fingerprint, presence: true

  def self.generate_pin
    SecureRandom.random_number(10**PIN_LENGTH).to_s.rjust(PIN_LENGTH, "0")
  end

  def self.pin_fingerprint(competition_id, pin)
    OpenSSL::HMAC.hexdigest(
      "SHA256",
      pin_pepper,
      "#{competition_id}:#{pin}"
    )
  end

  def self.pin_digest(pin)
    cost = Rails.env.test? ? BCrypt::Engine::MIN_COST : BCrypt::Engine.cost
    BCrypt::Password.create(pin, cost: cost).to_s
  end

  def self.authenticate_pin(competition, pin)
    fingerprint = pin_fingerprint(competition.id, pin.to_s)
    team = competition.robotics_teams.find_by(pin_fingerprint: fingerprint)
    return unless team
    return unless team.enabled?
    return unless BCrypt::Password.new(team.pin_digest).is_password?(pin.to_s)

    team
  rescue BCrypt::Errors::InvalidHash
    nil
  end

  def rotate_pin!
    with_lock do
      pin = nil
      fingerprint = nil

      loop do
        pin = self.class.generate_pin
        fingerprint = self.class.pin_fingerprint(robotics_competition_id, pin)
        break unless robotics_competition.robotics_teams
          .where.not(id: id)
          .exists?(pin_fingerprint: fingerprint)
      end

      update_columns(
        pin_digest: self.class.pin_digest(pin),
        pin_fingerprint: fingerprint,
        authentication_version: authentication_version + 1,
        updated_at: Time.current
      )
      pin
    end
  end

  def allocated_seconds
    robotics_time_entries
      .where.not(kind: RoboticsTimeEntry::SESSION_USAGE)
      .sum(:amount_seconds)
  end

  def used_seconds
    -robotics_time_entries
      .where(kind: RoboticsTimeEntry::SESSION_USAGE)
      .sum(:amount_seconds)
  end

  def balance_seconds
    robotics_time_entries.sum(:amount_seconds)
  end

  def name_with_competition
    "#{name} — #{robotics_competition.name}"
  end

  rails_admin do
    object_label_method :name_with_competition
    navigation_label "Robotics"

    list do
      field :name
      field :robotics_competition
      field :position
      field :enabled
      field :ready
      field :allocated_seconds
      field :used_seconds
      field :balance_seconds do
        label "Remaining seconds"
      end
    end

    show do
      field :name
      field :robotics_competition
      field :position
      field :enabled
      field :ready
      field :cooldown_until
      field :allocated_seconds
      field :used_seconds
      field :balance_seconds do
        label "Remaining seconds"
      end
      field :robotics_turns
      field :robotics_time_entries
    end

    edit do
      field :name
      field :position
      field :enabled
    end
  end

  class << self
    private

    def pin_pepper
      @pin_pepper ||= Rails.application.key_generator.generate_key(
        "robotics-team-pin-fingerprint",
        32
      )
    end
  end
end
