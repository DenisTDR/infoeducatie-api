require "rails_helper"

RSpec.describe "Integration competition results API", type: :request do
  let(:admin) { create(:admin_user) }
  let!(:competition) do
    create(
      :edition,
      year: 2026,
      name: "National 2026",
      current: false,
      show_results: false
    )
  end
  let!(:first_project) do
    create_project_for(
      competition,
      title: "Atlas",
      score: 25,
      extra_score: 4.5,
      prize: "III"
    )
  end
  let!(:second_project) do
    create_project_for(
      competition,
      title: "Beacon",
      score: 30,
      extra_score: 2,
      prize: nil
    )
  end

  def create_project_for(edition, attributes = {})
    contestant = create(:contestant, edition: edition)

    create(
      :project,
      {
        category: Category.find_by!(name: "roboti"),
        contestants: [contestant],
        edition: edition,
        finished: true,
        status: Project::STATUS_APPROVED,
        score: 0,
        extra_score: 0,
        prize: nil
      }.merge(attributes)
    )
  end

  def issue_token(scopes)
    ApiCredential.issue!(
      {
        name: "Results request spec",
        scopes: scopes,
        expires_at: 90.days.from_now
      },
      created_by: admin
    )
  end

  def authorization(token)
    {"Authorization" => "Bearer #{token}"}
  end

  def endpoint(edition = competition)
    "/v1/integrations/competitions/#{edition.id}/results"
  end

  def put_results(payload, token:, path: endpoint)
    put path,
      params: payload,
      headers: authorization(token),
      as: :json
  end

  def result_attributes(project)
    project.reload.attributes.slice(
      "score",
      "extra_score",
      "total_score",
      "prize"
    )
  end

  it "requires a service API key with the competition results write scope" do
    put endpoint,
      params: {projects: [], conclude: false},
      as: :json

    expect(response).to have_http_status(:unauthorized)

    _, token = issue_token([ApiCredential::COMPETITION_DATA_READ_SCOPE])
    put_results({projects: [], conclude: false}, token: token)

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.dig("error", "required_scope")).to eq(
      ApiCredential::COMPETITION_RESULTS_WRITE_SCOPE
    )
  end

  it "returns the API error envelope for malformed JSON" do
    credential, token = issue_token(
      [ApiCredential::COMPETITION_RESULTS_WRITE_SCOPE]
    )

    put endpoint,
      params: '{"projects": [',
      headers: {"CONTENT_TYPE" => "application/json"}

    expect(response).to have_http_status(:unauthorized)

    expect do
      put endpoint,
        params: '{"projects": [',
        headers: authorization(token).merge(
          "CONTENT_TYPE" => "application/json"
        )
    end.to change { credential.reload.use_count }.by(1)

    expect(response).to have_http_status(:bad_request)
    expect(response.media_type).to eq("application/json")
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.parsed_body.dig("error", "code")).to eq("invalid_json")
    expect(response.parsed_body.dig("error", "request_id")).to be_present
  end

  it "updates a draft subset, preserves an omitted bonus, clears a blank place, and never unpublishes" do
    competition.update!(show_results: true)
    original_second_result = result_attributes(second_project)
    _, token = issue_token(
      [ApiCredential::COMPETITION_RESULTS_WRITE_SCOPE]
    )

    put_results(
      {
        projects: [
          {
            id: first_project.id,
            score: 81.25,
            place: ""
          }
        ],
        conclude: false
      },
      token: token
    )

    expect(response).to have_http_status(:ok)
    expect(first_project.reload).to have_attributes(
      score: 81.25,
      extra_score: 4.5,
      total_score: 85.75
    )
    expect(first_project.prize).to be_blank
    expect(result_attributes(second_project)).to eq(original_second_result)
    expect(competition.reload.show_results).to be(true)
  end

  it "updates every approved project and publishes the results when concluding" do
    _, token = issue_token(
      [ApiCredential::COMPETITION_RESULTS_WRITE_SCOPE]
    )

    put_results(
      {
        projects: [
          {
            id: first_project.id,
            score: 92.5,
            extra_score: 0,
            place: "I"
          },
          {
            id: second_project.id,
            score: 87,
            extra_score: 1.5,
            place: "II"
          }
        ],
        conclude: true
      },
      token: token
    )

    expect(response).to have_http_status(:ok)
    expect(first_project.reload).to have_attributes(
      score: 92.5,
      extra_score: 0,
      total_score: 92.5,
      prize: "I"
    )
    expect(second_project.reload).to have_attributes(
      score: 87,
      extra_score: 1.5,
      total_score: 88.5,
      prize: "II"
    )
    expect(competition.reload.show_results).to be(true)
    expect(response.parsed_body.dig("data", "competition", "id")).to eq(
      competition.id
    )
  end

  it "allows an identical conclusion payload to be replayed safely" do
    _, token = issue_token(
      [ApiCredential::COMPETITION_RESULTS_WRITE_SCOPE]
    )
    payload = {
      projects: [
        {
          id: first_project.id,
          score: 91,
          extra_score: 3,
          place: "I"
        },
        {
          id: second_project.id,
          score: 84,
          extra_score: 0,
          place: "II"
        }
      ],
      conclude: true
    }

    2.times do
      put_results(payload, token: token)
      expect(response).to have_http_status(:ok)
    end

    expect(result_attributes(first_project)).to eq(
      "score" => 91.0,
      "extra_score" => 3.0,
      "total_score" => 94.0,
      "prize" => "I"
    )
    expect(result_attributes(second_project)).to eq(
      "score" => 84.0,
      "extra_score" => 0.0,
      "total_score" => 84.0,
      "prize" => "II"
    )
    expect(competition.reload.show_results).to be(true)
  end

  it "strictly rejects malformed and invalid result values without writing" do
    _, token = issue_token(
      [ApiCredential::COMPETITION_RESULTS_WRITE_SCOPE]
    )
    original_first_result = result_attributes(first_project)
    invalid_payloads = [
      {projects: [], conclude: false},
      {projects: {}, conclude: false},
      {projects: ["not-an-object"], conclude: false},
      {
        projects: [{id: 0, score: 80, place: nil}],
        conclude: false
      },
      {
        projects: [{id: first_project.id, score: "80", place: nil}],
        conclude: false
      },
      {
        projects: [{id: first_project.id, score: -1, place: nil}],
        conclude: false
      },
      {
        projects: [
          {
            id: first_project.id,
            score: 80,
            extra_score: nil,
            place: nil
          }
        ],
        conclude: false
      },
      {
        projects: [
          {
            id: first_project.id,
            score: 80,
            extra_score: "2",
            place: nil
          }
        ],
        conclude: false
      },
      {
        projects: [
          {
            id: first_project.id,
            score: 80,
            extra_score: -1,
            place: nil
          }
        ],
        conclude: false
      },
      {
        projects: [
          {
            id: first_project.id,
            score: 1e308,
            extra_score: 1e308,
            place: nil
          }
        ],
        conclude: false
      },
      {
        projects: [{id: first_project.id, score: 80, place: 1}],
        conclude: false
      },
      {
        projects: [{id: first_project.id, score: 80, place: "first"}],
        conclude: false
      },
      {
        projects: [{id: first_project.id, score: 80, place: nil}],
        conclude: "true"
      },
      {
        projects: [{id: first_project.id, score: 80, place: nil}]
      },
      {
        projects: [{id: first_project.id, place: nil}],
        conclude: false
      },
      {
        projects: [{id: first_project.id, score: 80}],
        conclude: false
      }
    ]

    invalid_payloads.each do |payload|
      put_results(payload, token: token)

      expect(response).to have_http_status(:unprocessable_content), payload.inspect
      expect(response.parsed_body.dig("error", "code")).to eq(
        "invalid_payload"
      ), payload.inspect
      expect(result_attributes(first_project)).to eq(original_first_result)
      expect(competition.reload.show_results).to be(false)
    end
  end

  it "rejects duplicate project IDs atomically" do
    _, token = issue_token(
      [ApiCredential::COMPETITION_RESULTS_WRITE_SCOPE]
    )
    original_first_result = result_attributes(first_project)

    put_results(
      {
        projects: [
          {id: first_project.id, score: 99, place: "I"},
          {id: first_project.id, score: 98, place: "II"}
        ],
        conclude: false
      },
      token: token
    )

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq(
      "invalid_payload"
    )
    expect(result_attributes(first_project)).to eq(original_first_result)
  end

  it "rejects foreign and ineligible projects atomically" do
    other_competition = create(
      :edition,
      year: 2027,
      name: "National 2027",
      current: false,
      show_results: false
    )
    foreign_project = create_project_for(other_competition, title: "Foreign")
    ineligible_project = create_project_for(
      competition,
      title: "Waiting",
      status: Project::STATUS_WAITING
    )
    _, token = issue_token(
      [ApiCredential::COMPETITION_RESULTS_WRITE_SCOPE]
    )
    original_first_result = result_attributes(first_project)

    [foreign_project, ineligible_project].each do |invalid_project|
      put_results(
        {
          projects: [
            {id: first_project.id, score: 99, place: "I"},
            {id: invalid_project.id, score: 80, place: nil}
          ],
          conclude: false
        },
        token: token
      )

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq(
        "invalid_payload"
      )
      expect(result_attributes(first_project)).to eq(original_first_result)
    end
  end

  it "requires complete approved-project coverage before concluding and writes nothing on failure" do
    _, token = issue_token(
      [ApiCredential::COMPETITION_RESULTS_WRITE_SCOPE]
    )
    original_first_result = result_attributes(first_project)

    put_results(
      {
        projects: [
          {id: first_project.id, score: 99, extra_score: 1, place: "I"}
        ],
        conclude: true
      },
      token: token
    )

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq(
      "incomplete_results"
    )
    expect(result_attributes(first_project)).to eq(original_first_result)
    expect(competition.reload.show_results).to be(false)
  end

  it "does not conclude an unpublished competition" do
    competition.update!(published: false)
    _, token = issue_token(
      [ApiCredential::COMPETITION_RESULTS_WRITE_SCOPE]
    )
    original_first_result = result_attributes(first_project)

    put_results(
      {
        projects: [
          {id: first_project.id, score: 90, place: "I"},
          {id: second_project.id, score: 80, place: "II"}
        ],
        conclude: true
      },
      token: token
    )

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq(
      "competition_not_published"
    )
    expect(result_attributes(first_project)).to eq(original_first_result)
    expect(competition.reload.show_results).to be(false)
  end

  it "distinguishes invalid competition IDs from competitions that do not exist" do
    _, token = issue_token(
      [ApiCredential::COMPETITION_RESULTS_WRITE_SCOPE]
    )
    payload = {
      projects: [{id: first_project.id, score: 80, place: nil}],
      conclude: false
    }

    ["not-an-id", "-1", "999999999999999999999"].each do |competition_id|
      put_results(
        payload,
        token: token,
        path: "/v1/integrations/competitions/#{competition_id}/results"
      )

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body.dig("error", "code")).to eq(
        "invalid_competition_id"
      )
    end

    put_results(
      payload,
      token: token,
      path: "/v1/integrations/competitions/2147483647/results"
    )

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.dig("error", "code")).to eq(
      "competition_not_found"
    )
    expect(result_attributes(first_project)).to eq(
      "score" => 25.0,
      "extra_score" => 4.5,
      "total_score" => 29.5,
      "prize" => "III"
    )
  end
end
