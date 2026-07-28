module RailsAdmin
  module Config
    module Actions
      class ForceStopRoboticsTurn < RailsAdmin::Config::Actions::Base
        RailsAdmin::Config::Actions.register(self)

        register_instance_option :member do
          true
        end

        register_instance_option :link_icon do
          "fas fa-stop-circle"
        end

        register_instance_option :visible? do
          bindings[:object].is_a?(::RoboticsTurn) &&
            bindings[:object].active?
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

            reason = params.require(:force_stop).fetch(:reason)
            ::Robotics::CompetitionCoordinator.force_stop!(
              @object,
              actor: current_user,
              reason: reason
            )
            Rails.logger.info(
              "Robotics turn force-stopped turn_id=#{@object.id} " \
              "admin_user_id=#{current_user.id}"
            )
            flash[:success] = "The active robotics turn was stopped."
            redirect_to index_path
          rescue ::Robotics::TransitionError, ActionController::ParameterMissing,
            KeyError => error
            @force_stop_error = error
            response.status = :unprocessable_content
            render @action.template_name
          end
        end
      end
    end
  end
end
