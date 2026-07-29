module RailsAdmin
  module Config
    module Actions
      class RegenerateRoboticsTeamPin < RailsAdmin::Config::Actions::Base
        RESULT_FLASH_KEY = :robotics_team_pin_result

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
              result_payload = flash[RESULT_FLASH_KEY]
              unless result_payload
                render @action.template_name
                next
              end
              flash.delete(RESULT_FLASH_KEY)

              unless result_payload.fetch("team_id") == @object.id
                flash[:error] =
                  "The regenerated PIN result belongs to another team."
                redirect_to index_path, status: :see_other
                next
              end

              @plaintext_pin = result_payload.fetch("pin")
              response.headers["Cache-Control"] = "no-store, max-age=0"
              response.headers["Pragma"] = "no-cache"
              @turbo_cache_control = "no-cache"
              render "rails_admin/main/regenerate_robotics_team_pin_result"
              next
            end

            plaintext_pin = @object.rotate_pin!
            Rails.logger.info(
              "Robotics team PIN regenerated team_id=#{@object.id} " \
              "admin_user_id=#{current_user.id}"
            )
            flash[RESULT_FLASH_KEY] = {
              "team_id" => @object.id,
              "pin" => plaintext_pin
            }
            redirect_to request.path, status: :see_other
          end
        end
      end
    end
  end
end
