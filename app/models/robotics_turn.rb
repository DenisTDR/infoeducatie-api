class RoboticsTurn < ActiveRecord::Base
  LIVE_STATES = %w[offered active turnover].freeze
  TERMINAL_STATES = %w[completed passed expired withdrawn].freeze
  STATES = (LIVE_STATES + TERMINAL_STATES).freeze

  belongs_to :robotics_competition, inverse_of: :robotics_turns
  belongs_to :robotics_team, inverse_of: :robotics_turns
  belongs_to :stopped_by, class_name: "User", optional: true
  has_one :robotics_time_entry,
    dependent: :restrict_with_error,
    inverse_of: :robotics_turn

  validates :robotics_competition,
    :robotics_team,
    :state,
    :offered_at,
    :offer_expires_at,
    presence: true
  validates :state, inclusion: {in: STATES}
  validates :sequence_number,
    presence: true,
    uniqueness: {scope: :robotics_competition_id}
  validates :reserved_seconds,
    numericality: {only_integer: true, greater_than: 0},
    allow_nil: true
  validates :charged_seconds,
    numericality: {only_integer: true, greater_than_or_equal_to: 0},
    allow_nil: true
  validate :team_belongs_to_competition
  validate :offer_window_is_valid
  validate :active_fields_are_present

  scope :live_lease, -> { where(state: LIVE_STATES) }

  def live_lease?
    state.in?(LIVE_STATES)
  end

  def active?
    state == "active"
  end

  def offered?
    state == "offered"
  end

  def turnover?
    state == "turnover"
  end

  def label
    "Turn ##{sequence_number} — #{robotics_team.name}"
  end

  rails_admin do
    object_label_method :label
    navigation_label "Robotics"

    list do
      field :sequence_number
      field :robotics_competition
      field :robotics_team
      field :state
      field :offered_at
      field :started_at
      field :ended_at
      field :charged_seconds
    end

    show do
      field :sequence_number
      field :robotics_competition
      field :robotics_team
      field :state
      field :offered_at
      field :offer_expires_at
      field :started_at
      field :session_ends_at
      field :ended_at
      field :turnover_ends_at
      field :reserved_seconds
      field :charged_seconds
      field :stop_reason
      field :stopped_by
      field :robotics_time_entry
    end
  end

  private

  def team_belongs_to_competition
    return if robotics_team.blank? || robotics_competition.blank?
    return if robotics_team.robotics_competition_id == robotics_competition_id

    errors.add(:robotics_team, "must belong to the competition")
  end

  def offer_window_is_valid
    return if offered_at.blank? || offer_expires_at.blank?
    return if offer_expires_at >= offered_at

    errors.add(:offer_expires_at, "must not precede the offer")
  end

  def active_fields_are_present
    return unless state.in?(%w[active turnover completed])
    return if started_at.present? &&
      session_ends_at.present? &&
      reserved_seconds.present?

    errors.add(:base, "started turns require timing and reservation fields")
  end
end
