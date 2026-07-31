module V1
  module Integrations
    class CompetitionResultsController < BaseController
      MAX_DATABASE_ID = 2_147_483_647

      wrap_parameters false

      before_action -> {
        require_api_scope!(ApiCredential::COMPETITION_RESULTS_WRITE_SCOPE)
      }

      def update
        competition = find_competition
        return unless competition

        result = ::Integrations::UpdateCompetitionResults.call(
          competition: competition,
          payload: request.request_parameters
        )

        log_results_update(result)
        render json: result_payload(result)
      rescue ::Integrations::UpdateCompetitionResults::InvalidPayload => error
        render_api_error(
          code: error.code,
          message: error.message,
          status: :unprocessable_content,
          details: {issues: error.issues}
        )
      end

      private

      def find_competition
        competition_id = Integer(params[:competition_id], 10)
        unless competition_id.between?(1, MAX_DATABASE_ID)
          render_invalid_competition_id
          return
        end

        competition = Edition.find_by(id: competition_id)
        return competition if competition

        render_api_error(
          code: "competition_not_found",
          message: "No competition matches the requested ID.",
          status: :not_found
        )
        nil
      rescue ArgumentError, TypeError, RangeError
        render_invalid_competition_id
        nil
      end

      def render_invalid_competition_id
        render_api_error(
          code: "invalid_competition_id",
          message: "competition_id must be a positive integer.",
          status: :bad_request
        )
      end

      def log_results_update(result)
        Rails.logger.info(
          "Integration competition results updated " \
          "credential_id=#{current_api_credential.id} " \
          "competition_id=#{result.competition.id} " \
          "project_count=#{result.projects.length} " \
          "concluded=#{result.competition.show_results?} " \
          "request_id=#{request.request_id}"
        )
      end

      def result_payload(result)
        {
          data: {
            competition: {
              id: result.competition.id,
              year: result.competition.year,
              name: result.competition.name,
              concluded: result.competition.show_results?
            },
            projects: result.projects.map { |project|
              {
                id: project.id,
                score: project.score,
                extra_score: project.extra_score,
                total_score: project.total_score,
                place: project.prize
              }
            }
          },
          meta: {
            updated_count: result.projects.length,
            generated_at: Time.current.iso8601(3)
          }
        }
      end
    end
  end
end
