require "rails_helper"

RSpec.describe "RailsAdmin robotics translations" do
  action_keys = %i[
    create_robotics_competition
    adjust_robotics_team_time
    regenerate_robotics_team_pin
    force_stop_robotics_turn
  ]

  %i[en ro].product(action_keys, %i[title menu breadcrumb]).each do |locale, action, attribute|
    key = "admin.actions.#{action}.#{attribute}"

    it "defines #{key} in #{locale}" do
      expect(I18n.exists?(key, locale, fallback: false)).to be(true)
    end
  end
end
