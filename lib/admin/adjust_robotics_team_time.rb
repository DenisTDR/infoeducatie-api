module RailsAdmin
  module Config
    module Actions
      class AdjustRoboticsTeamTime < RailsAdmin::Config::Actions::Base
        RailsAdmin::Config::Actions.register(self)

        register_instance_option :member do
          true
        end

        register_instance_option :link_icon do
          "fas fa-clock"
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

            permitted = params.require(:time_adjustment).permit(
              :minutes,
              :reason
            )
            minutes = Integer(permitted.fetch(:minutes))
            ::Robotics::AdjustTime.call(
              team: @object,
              amount_seconds: minutes.minutes.to_i,
              reason: permitted.fetch(:reason),
              actor: current_user
            )
            Rails.logger.info(
              "Robotics team time adjusted team_id=#{@object.id} " \
              "seconds=#{minutes.minutes.to_i} admin_user_id=#{current_user.id}"
            )
            flash[:success] =
              "#{minutes.positive? ? 'Added' : 'Deducted'} " \
              "#{minutes.abs} minutes for #{@object.name}."
            redirect_to index_path
          rescue ::Robotics::TransitionError, ArgumentError, KeyError => error
            @adjustment_error = error
            response.status = :unprocessable_content
            render @action.template_name
          end
        end
      end
    end
  end
end
