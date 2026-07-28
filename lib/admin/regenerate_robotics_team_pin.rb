module RailsAdmin
  module Config
    module Actions
      class RegenerateRoboticsTeamPin < RailsAdmin::Config::Actions::Base
        RailsAdmin::Config::Actions.register(self)

        register_instance_option :member do
          true
        end

        register_instance_option :link_icon do
          "fas fa-key"
        end

        register_instance_option :http_methods do
          %i[get post]
        end

        register_instance_option :controller do
          proc do
            if request.get?
              render @action.template_name
              next
            end

            @plaintext_pin = @object.rotate_pin!
            response.headers["Cache-Control"] = "no-store, max-age=0"
            response.headers["Pragma"] = "no-cache"
            Rails.logger.info(
              "Robotics team PIN regenerated team_id=#{@object.id} " \
              "admin_user_id=#{current_user.id}"
            )
            render "rails_admin/main/regenerate_robotics_team_pin_result"
          end
        end
      end
    end
  end
end
