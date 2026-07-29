class RoboticsCompetition < ActiveRecord::Base
  DEFAULT_DURATION_SECONDS = 20.hours.to_i
  DEFAULT_TEAM_ALLOCATION_SECONDS = 3.hours.to_i
  DEFAULT_TURN_DURATION_SECONDS = 10.minutes.to_i
  DEFAULT_CLAIM_WINDOW_SECONDS = 60
  DEFAULT_TURNOVER_SECONDS = 60
  SCHEDULING_ATTRIBUTES = %w[
    starts_at
    duration_seconds
    turn_duration_seconds
    claim_window_seconds
    turnover_seconds
  ].freeze

  has_many :robotics_teams, dependent: :destroy, inverse_of: :robotics_competition
  has_many :robotics_queue_entries,
    dependent: :destroy,
    inverse_of: :robotics_competition
  has_many :robotics_turns, dependent: :destroy, inverse_of: :robotics_competition
  has_many :robotics_time_entries,
    dependent: :destroy,
    inverse_of: :robotics_competition

  validates :name, presence: true, length: {maximum: 120}
  validates :slug,
    presence: true,
    uniqueness: true,
    length: {maximum: 80},
    format: {with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/}
  validates :starts_at, presence: true
  validates :duration_seconds,
    numericality: {only_integer: true, greater_than: 0}
  validates :team_allocation_seconds,
    numericality: {only_integer: true, greater_than: 0}
  validates :turn_duration_seconds,
    numericality: {only_integer: true, greater_than: 0}
  validates :claim_window_seconds,
    numericality: {only_integer: true, greater_than: 0}
  validates :turnover_seconds,
    numericality: {only_integer: true, greater_than_or_equal_to: 0}
  validate :turn_fits_inside_competition
  validate :scheduling_changes_are_safe, on: :update

  before_validation :normalize_slug

  def ends_at
    starts_at && starts_at + duration_seconds.seconds
  end

  def duration_hours
    duration_seconds / 1.hour.to_f
  end

  def team_allocation_minutes
    team_allocation_seconds / 1.minute.to_f
  end

  def turn_duration_minutes
    turn_duration_seconds / 1.minute.to_f
  end

  def status(at: Time.current)
    return "scheduled" if at < starts_at
    return "live" if at < ends_at

    "ended"
  end

  def live?(at: Time.current)
    status(at: at) == "live"
  end

  def ended?(at: Time.current)
    status(at: at) == "ended"
  end

  def next_queue_sequence!
    self.queue_sequence += 1
    update_column(:queue_sequence, queue_sequence)
    queue_sequence
  end

  def next_turn_sequence!
    self.turn_sequence += 1
    update_column(:turn_sequence, turn_sequence)
    turn_sequence
  end

  def name_with_status
    "#{name} (#{status})"
  end

  rails_admin do
    object_label_method :name_with_status
    navigation_label "Robotics"

    list do
      field :name
      field :slug
      field :starts_at
      field :ends_at
      field :status
    end

    show do
      field :name
      field :slug
      field :starts_at
      field :ends_at
      field :duration_hours do
        label "Duration (hours)"
      end
      field :team_allocation_minutes do
        label "Time per team (minutes)"
      end
      field :turn_duration_minutes do
        label "Turn length (minutes)"
      end
      field :claim_window_seconds
      field :turnover_seconds
      field :robotics_teams
      field :robotics_turns
    end

    edit do
      field :name
      field :slug
      field :starts_at
      field :duration_seconds
      field :team_allocation_seconds
      field :turn_duration_seconds
      field :claim_window_seconds
      field :turnover_seconds
    end
  end

  private

  def normalize_slug
    generated_from_name = slug.blank?
    source = (slug.presence || name).to_s
    source = if source.encoding == Encoding::ASCII_8BIT
      source.dup.force_encoding(Encoding::UTF_8).scrub
    else
      source.encode(
        Encoding::UTF_8,
        invalid: :replace,
        undef: :replace,
        replace: ""
      )
    end
    normalized_slug = source
      .unicode_normalize(:nfkd)
      .gsub(/\p{Mn}/, "")
      .parameterize
    normalized_slug = normalized_slug.first(80).sub(/-+\z/, "") if generated_from_name
    self.slug = normalized_slug
  end

  def turn_fits_inside_competition
    return if duration_seconds.blank? || turn_duration_seconds.blank?
    return if turn_duration_seconds <= duration_seconds

    errors.add(:turn_duration_seconds, "cannot exceed the competition duration")
  end

  def scheduling_changes_are_safe
    changed_scheduling = changes_to_save.keys & SCHEDULING_ATTRIBUTES
    original_start = attribute_in_database("starts_at")

    if changed_scheduling.any? &&
        (robotics_turns.exists? || (original_start && Time.current >= original_start))
      errors.add(
        :base,
        "Competition timing cannot change after it starts or has turn history"
      )
    end

    if will_save_change_to_team_allocation_seconds? && robotics_teams.exists?
      errors.add(
        :team_allocation_seconds,
        "cannot change after teams receive their initial grants"
      )
    end
  end
end
