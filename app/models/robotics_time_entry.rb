class RoboticsTimeEntry < ActiveRecord::Base
  INITIAL_GRANT = "initial_grant"
  SESSION_USAGE = "session_usage"
  ADMIN_ADJUSTMENT = "admin_adjustment"
  KINDS = [INITIAL_GRANT, SESSION_USAGE, ADMIN_ADJUSTMENT].freeze

  belongs_to :robotics_competition, inverse_of: :robotics_time_entries
  belongs_to :robotics_team, inverse_of: :robotics_time_entries
  belongs_to :robotics_turn, optional: true, inverse_of: :robotics_time_entry
  belongs_to :actor, class_name: "User", optional: true

  validates :robotics_competition,
    :robotics_team,
    :kind,
    :amount_seconds,
    :reason,
    presence: true
  validates :kind, inclusion: {in: KINDS}
  validates :amount_seconds,
    numericality: {only_integer: true, other_than: 0}
  validates :robotics_turn_id, uniqueness: true, allow_nil: true
  validate :team_belongs_to_competition
  validate :kind_has_correct_shape

  def readonly?
    persisted?
  end

  def label
    "#{robotics_team.name}: #{amount_seconds >= 0 ? '+' : ''}#{amount_seconds}s"
  end

  rails_admin do
    object_label_method :label
    navigation_label "Robotics"

    list do
      field :created_at
      field :robotics_competition
      field :robotics_team
      field :kind
      field :amount_seconds
      field :reason
      field :actor
    end

    show do
      field :created_at
      field :robotics_competition
      field :robotics_team
      field :kind
      field :amount_seconds
      field :reason
      field :actor
      field :robotics_turn
    end
  end

  private

  def team_belongs_to_competition
    return if robotics_team.blank? || robotics_competition.blank?
    return if robotics_team.robotics_competition_id == robotics_competition_id

    errors.add(:robotics_team, "must belong to the competition")
  end

  def kind_has_correct_shape
    case kind
    when INITIAL_GRANT
      errors.add(:amount_seconds, "must be positive") unless amount_seconds.to_i.positive?
      errors.add(:robotics_turn, "must be blank") if robotics_turn_id.present?
    when SESSION_USAGE
      errors.add(:amount_seconds, "must be negative") unless amount_seconds.to_i.negative?
      errors.add(:robotics_turn, "must be present") if robotics_turn_id.blank?
    when ADMIN_ADJUSTMENT
      errors.add(:actor, "must be an administrator") unless actor&.admin?
    end
  end
end
