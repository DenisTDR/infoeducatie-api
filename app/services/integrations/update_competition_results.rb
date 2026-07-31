require "set"

module Integrations
  class UpdateCompetitionResults
    MAX_DATABASE_ID = 2_147_483_647
    MAX_PLACE_LENGTH = 3
    ALLOWED_PAYLOAD_KEYS = %w[projects conclude].freeze
    ALLOWED_PROJECT_KEYS = %w[id score extra_score place].freeze
    REQUIRED_PROJECT_KEYS = %w[id score place].freeze

    Result = Data.define(:competition, :projects)

    class InvalidPayload < StandardError
      attr_reader :code, :issues

      def initialize(code:, message:, issues:)
        @code = code
        @issues = issues
        super(message)
      end
    end

    def self.call(competition:, payload:)
      new(competition: competition, payload: payload).call
    end

    def initialize(competition:, payload:)
      @competition = competition
      @payload = normalize_hash(payload)
    end

    def call
      validate_payload!
      updated_projects = []

      competition.with_lock do
        validate_conclusion_state!
        locked_projects = competition.projects.lock.order(:id).to_a
        eligible_projects = locked_projects.select { |project|
          project.finished? && project.status == Project::STATUS_APPROVED
        }
        normalized_projects = validate_projects!(eligible_projects)

        normalized_projects.each do |result|
          project = result.fetch(:project)
          project.assign_attributes(result.fetch(:attributes))
          project.save!
          updated_projects << project
        end

        competition.update!(show_results: true) if conclude && !competition.show_results?
      end

      Result.new(
        competition: competition,
        projects: updated_projects
      )
    rescue ActiveRecord::RecordInvalid => error
      raise InvalidPayload.new(
        code: "results_update_failed",
        message: "The results could not be saved.",
        issues: [
          {
            path: "projects",
            code: "record_invalid",
            message: error.record.errors.full_messages.to_sentence
          }
        ]
      )
    end

    private

    attr_reader :competition, :payload, :projects, :conclude

    def normalize_hash(value)
      value = value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
      return value.deep_stringify_keys if value.is_a?(Hash)

      value
    end

    def validate_payload!
      unless payload.is_a?(Hash)
        raise_invalid_payload("The request body must be a JSON object.")
      end

      issues = []
      unexpected_keys = payload.keys - ALLOWED_PAYLOAD_KEYS
      unexpected_keys.each do |key|
        issues << issue(
          path: key,
          code: "unexpected_field",
          message: "is not supported"
        )
      end

      unless payload.key?("projects")
        issues << issue(
          path: "projects",
          code: "required",
          message: "is required"
        )
      end
      unless payload["projects"].is_a?(Array) && payload["projects"].any?
        issues << issue(
          path: "projects",
          code: "must_be_non_empty_array",
          message: "must be a non-empty array"
        )
      end

      unless payload.key?("conclude")
        issues << issue(
          path: "conclude",
          code: "required",
          message: "is required"
        )
      end
      unless payload["conclude"].in?([true, false])
        issues << issue(
          path: "conclude",
          code: "must_be_boolean",
          message: "must be true or false"
        )
      end

      raise_invalid_payload(issues: issues) if issues.any?

      @projects = payload.fetch("projects")
      @conclude = payload.fetch("conclude")
    end

    def validate_projects!(eligible_projects)
      eligible_by_id = eligible_projects.index_by(&:id)
      issues = []
      normalized_projects = []
      seen_ids = Set.new

      projects.each_with_index do |raw_project, index|
        path = "projects[#{index}]"
        unless raw_project.is_a?(Hash)
          issues << issue(
            path: path,
            code: "must_be_object",
            message: "must be an object"
          )
          next
        end

        project_payload = raw_project.deep_stringify_keys
        item_issues = validate_project_fields(project_payload, path)
        project_id = project_payload["id"]

        if valid_database_id?(project_id)
          if seen_ids.include?(project_id)
            item_issues << issue(
              path: "#{path}.id",
              code: "duplicate",
              message: "must not be repeated"
            )
          else
            seen_ids << project_id
          end

          unless eligible_by_id.key?(project_id)
            item_issues << issue(
              path: "#{path}.id",
              code: "ineligible_project",
              message: "must identify an approved, finished project in this competition"
            )
          end
        end

        if item_issues.empty?
          effective_extra_score = if project_payload.key?("extra_score")
            project_payload.fetch("extra_score").to_f
          else
            eligible_by_id.fetch(project_id).extra_score.to_f
          end
          total_score = project_payload.fetch("score").to_f + effective_extra_score
          unless valid_score?(effective_extra_score)
            item_issues << issue(
              path: "#{path}.extra_score",
              code: "must_be_non_negative_number",
              message: "the stored or supplied value must be finite and non-negative"
            )
          end
          unless total_score.finite?
            item_issues << issue(
              path: "#{path}",
              code: "total_score_out_of_range",
              message: "score plus extra_score must be a finite number"
            )
          end
        end

        issues.concat(item_issues)
        next if item_issues.any?

        attributes = {
          score: project_payload.fetch("score").to_f,
          prize: normalize_place(project_payload.fetch("place"))
        }
        if project_payload.key?("extra_score")
          attributes[:extra_score] = project_payload.fetch("extra_score").to_f
        end

        normalized_projects << {
          project: eligible_by_id.fetch(project_id),
          attributes: attributes
        }
      end

      raise_invalid_payload(issues: issues) if issues.any?
      validate_complete_results!(eligible_projects, seen_ids)
      normalized_projects
    end

    def validate_conclusion_state!
      return unless conclude && !competition.published?

      raise InvalidPayload.new(
        code: "competition_not_published",
        message: "A competition must be published before it can be concluded.",
        issues: [
          issue(
            path: "conclude",
            code: "competition_not_published",
            message: "cannot be true for an unpublished competition"
          )
        ]
      )
    end

    def validate_project_fields(project_payload, path)
      issues = []

      (project_payload.keys - ALLOWED_PROJECT_KEYS).each do |key|
        issues << issue(
          path: "#{path}.#{key}",
          code: "unexpected_field",
          message: "is not supported"
        )
      end

      (REQUIRED_PROJECT_KEYS - project_payload.keys).each do |key|
        issues << issue(
          path: "#{path}.#{key}",
          code: "required",
          message: "is required"
        )
      end

      if project_payload.key?("id") &&
          !valid_database_id?(project_payload["id"])
        issues << issue(
          path: "#{path}.id",
          code: "must_be_positive_integer",
          message: "must be a positive integer"
        )
      end

      if project_payload.key?("score") &&
          !valid_score?(project_payload["score"])
        issues << issue(
          path: "#{path}.score",
          code: "must_be_non_negative_number",
          message: "must be a finite, non-negative JSON number"
        )
      end

      if project_payload.key?("extra_score") &&
          !valid_score?(project_payload["extra_score"])
        issues << issue(
          path: "#{path}.extra_score",
          code: "must_be_non_negative_number",
          message: "must be a finite, non-negative JSON number"
        )
      end

      if project_payload.key?("place") &&
          !valid_place?(project_payload["place"])
        issues << issue(
          path: "#{path}.place",
          code: "invalid_place",
          message: "must be null or a string of at most #{MAX_PLACE_LENGTH} characters"
        )
      end

      issues
    end

    def validate_complete_results!(eligible_projects, submitted_ids)
      return unless conclude

      missing_ids = eligible_projects.map(&:id).to_set - submitted_ids
      return if missing_ids.empty?

      raise InvalidPayload.new(
        code: "incomplete_results",
        message: "Every approved, finished project must be included before concluding.",
        issues: [
          issue(
            path: "projects",
            code: "missing_projects",
            message: "is missing approved project IDs: #{missing_ids.to_a.sort.join(", ")}"
          )
        ]
      )
    end

    def valid_database_id?(value)
      value.is_a?(Integer) && value.between?(1, MAX_DATABASE_ID)
    end

    def valid_score?(value)
      value.is_a?(Numeric) && value.to_f.finite? && value >= 0
    end

    def valid_place?(value)
      value.nil? ||
        (value.is_a?(String) && value.strip.length <= MAX_PLACE_LENGTH)
    end

    def normalize_place(value)
      value&.strip.presence
    end

    def issue(path:, code:, message:)
      {path: path, code: code, message: message}
    end

    def raise_invalid_payload(message = nil, issues: nil)
      raise InvalidPayload.new(
        code: "invalid_payload",
        message: message || "One or more result values are invalid.",
        issues: issues || []
      )
    end
  end
end
