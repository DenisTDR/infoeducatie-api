class RoboticsQueueEntry < ActiveRecord::Base
  belongs_to :robotics_competition, inverse_of: :robotics_queue_entries
  belongs_to :robotics_team, inverse_of: :robotics_queue_entry

  validates :robotics_competition, :robotics_team, :requested_at, presence: true
  validates :robotics_team_id, uniqueness: true
  validates :sequence_number,
    presence: true,
    uniqueness: {scope: :robotics_competition_id}
  validate :team_belongs_to_competition

  private

  def team_belongs_to_competition
    return if robotics_team.blank? || robotics_competition.blank?
    return if robotics_team.robotics_competition_id == robotics_competition_id

    errors.add(:robotics_team, "must belong to the competition")
  end
end
