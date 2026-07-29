module RailsAdmin
  module Config
    module Actions
      class CreateRoboticsCompetition < RailsAdmin::Config::Actions::Base
        RESULT_FLASH_KEY = :robotics_competition_result

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
              result_payload = flash[RESULT_FLASH_KEY]
              unless result_payload
                render @action.template_name
                next
              end
              flash.delete(RESULT_FLASH_KEY)

              @robotics_competition = ::RoboticsCompetition.find(
                result_payload.fetch("competition_id")
              )
              issued_pins = result_payload.fetch("issued_pins")
              teams_by_id = @robotics_competition.robotics_teams
                .where(id: issued_pins.pluck("team_id"))
                .index_by(&:id)
              @issued_pins = issued_pins.map do |issued|
                {
                  team: teams_by_id.fetch(issued.fetch("team_id")),
                  pin: issued.fetch("pin")
                }
              end
              response.headers["Cache-Control"] = "no-store, max-age=0"
              response.headers["Pragma"] = "no-cache"
              @turbo_cache_control = "no-cache"
              render "rails_admin/main/create_robotics_competition_result"
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
            Rails.logger.info(
              "Robotics competition created " \
              "competition_id=#{@robotics_competition.id} " \
              "team_count=#{@issued_pins.length} " \
              "admin_user_id=#{current_user.id}"
            )
            flash[RESULT_FLASH_KEY] = {
              "competition_id" => @robotics_competition.id,
              "issued_pins" => @issued_pins.map do |issued|
                {
                  "team_id" => issued.fetch(:team).id,
                  "pin" => issued.fetch(:pin)
                }
              end
            }
            redirect_to request.path, status: :see_other
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
