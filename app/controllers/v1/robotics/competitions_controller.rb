module V1
  module Robotics
    class CompetitionsController < ApiController
      before_action :disable_response_caching
      before_action :load_competition
      before_action :load_team_from_token, except: :authenticate

      rate_limit(
        to: 10,
        within: 1.minute,
        by: -> { "robotics-pin:#{params[:slug]}:#{request.remote_ip}" },
        only: :authenticate,
        name: "robotics-pin-authentication",
        scope: "robotics",
        with: -> {
          render_error(
            code: "rate_limit_exceeded",
            message: "Too many PIN attempts. Try again in one minute.",
            status: :too_many_requests
          )
        }
      )

      def show
        ::Robotics::CompetitionCoordinator.sync_if_needed!(@competition)
        render_state
      end

      def authenticate
        pin = params[:pin].to_s
        team = ::RoboticsTeam.authenticate_pin(@competition, pin)
        unless team
          render_error(
            code: "invalid_pin",
            message: "The team PIN is invalid.",
            status: :unauthorized
          )
          return
        end

        ::Robotics::CompetitionCoordinator.sync!(@competition)
        token = ::Robotics::TeamToken.issue(team)
        render json: {
          token: token,
          state: state_payload(viewer: team.reload)
        }
      end

      def readiness
        return unless require_team!
        unless params.key?(:ready) && [true, false].include?(params[:ready])
          render_error(
            code: "invalid_readiness",
            message: "ready must be true or false.",
            status: :unprocessable_content
          )
          return
        end

        ::Robotics::CompetitionCoordinator.set_readiness!(
          @competition,
          team: @current_robotics_team,
          ready: params[:ready]
        )
        render_state
      end

      def claim
        return unless require_team!

        ::Robotics::CompetitionCoordinator.claim!(
          @competition,
          team: @current_robotics_team,
          turn_id: requested_turn_id
        )
        render_state
      end

      def pass
        return unless require_team!

        ::Robotics::CompetitionCoordinator.pass!(
          @competition,
          team: @current_robotics_team,
          turn_id: requested_turn_id
        )
        render_state
      end

      def stop
        return unless require_team!

        ::Robotics::CompetitionCoordinator.stop!(
          @competition,
          team: @current_robotics_team,
          turn_id: requested_turn_id
        )
        render_state
      end

      private

      def load_competition
        @competition = ::RoboticsCompetition.find_by(slug: params[:slug])
        return if @competition

        render_error(
          code: "competition_not_found",
          message: "The robotics competition was not found.",
          status: :not_found
        )
      end

      def load_team_from_token
        return unless @competition

        authorization = request.headers["Authorization"].to_s
        return if authorization.blank?

        match = /\ATeam\s+(.+)\z/.match(authorization)
        @current_robotics_team = if match
          ::Robotics::TeamToken.authenticate(
            match[1],
            competition: @competition
          )
        end
        return if @current_robotics_team

        render_error(
          code: "invalid_team_token",
          message: "The team authentication token is invalid or expired.",
          status: :unauthorized
        )
      end

      def require_team!
        return true if @current_robotics_team
        return false if performed?

        render_error(
          code: "team_authentication_required",
          message: "Authenticate with a team PIN first.",
          status: :unauthorized
        )
        false
      end

      def render_state
        render json: state_payload(viewer: @current_robotics_team&.reload)
      end

      def requested_turn_id
        turn_id = Integer(params[:turn_id].to_s, 10)
        return turn_id if turn_id.positive?

        raise ArgumentError
      rescue ArgumentError, TypeError
        raise ::Robotics::TransitionError.new(
          "invalid_turn_id",
          "turn_id must be a positive integer.",
          status: :unprocessable_content
        )
      end

      def state_payload(viewer:)
        ::Robotics::CompetitionStateSerializer.new(
          @competition.reload,
          viewer: viewer
        ).as_json
      end

      def render_error(code:, message:, status:)
        render json: {
          error: {
            code: code,
            message: message
          }
        }, status: status
      end

      def disable_response_caching
        response.headers["Cache-Control"] = "no-store, max-age=0"
        response.headers["Pragma"] = "no-cache"
      end

      rescue_from ::Robotics::TransitionError do |error|
        render_error(
          code: error.code,
          message: error.message,
          status: error.status
        )
      end
    end
  end
end
