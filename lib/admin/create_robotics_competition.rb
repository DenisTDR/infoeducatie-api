module RailsAdmin
  module Config
    module Actions
      class CreateRoboticsCompetition < RailsAdmin::Config::Actions::Base
        RailsAdmin::Config::Actions.register(self)

        register_instance_option :collection do
          true
        end

        register_instance_option :link_icon do
          "fas fa-flag-checkered"
        end

        register_instance_option :http_methods do
          %i[get post]
        end

        register_instance_option :controller do
          proc do
            @defaults = {
              duration_hours: 20,
              team_count: 5,
              team_allocation_minutes: 180,
              turn_duration_minutes: 10,
              claim_window_seconds: 60,
              turnover_seconds: 60
            }

            if request.get?
              render @action.template_name
              next
            end

            permitted = params.require(:robotics_competition).permit(
              :name,
              :slug,
              :starts_at,
              :duration_hours,
              :team_count,
              :team_allocation_minutes,
              :turn_duration_minutes,
              :claim_window_seconds,
              :turnover_seconds
            )
            starts_at = Time.zone.parse(permitted.fetch(:starts_at))
            raise ArgumentError, "starts_at is invalid" unless starts_at

            result = ::Robotics::CreateCompetition.call(
              {
                name: permitted.fetch(:name),
                slug: permitted[:slug],
                starts_at: starts_at,
                duration_seconds:
                  Integer(permitted.fetch(:duration_hours)).hours.to_i,
                team_allocation_seconds:
                  Integer(permitted.fetch(:team_allocation_minutes)).minutes.to_i,
                turn_duration_seconds:
                  Integer(permitted.fetch(:turn_duration_minutes)).minutes.to_i,
                claim_window_seconds:
                  Integer(permitted.fetch(:claim_window_seconds)),
                turnover_seconds:
                  Integer(permitted.fetch(:turnover_seconds))
              },
              team_count: permitted.fetch(:team_count)
            )
            @robotics_competition = result.competition
            @issued_pins = result.issued_pins
            response.headers["Cache-Control"] = "no-store, max-age=0"
            response.headers["Pragma"] = "no-cache"
            Rails.logger.info(
              "Robotics competition created " \
              "competition_id=#{@robotics_competition.id} " \
              "team_count=#{@issued_pins.length} " \
              "admin_user_id=#{current_user.id}"
            )
            render "rails_admin/main/create_robotics_competition_result"
          rescue ActiveRecord::RecordInvalid, ArgumentError, KeyError => error
            @creation_error = error
            @submitted = params[:robotics_competition]&.to_unsafe_h || {}
            response.status = :unprocessable_content
            render @action.template_name
          end
        end
      end
    end
  end
end
