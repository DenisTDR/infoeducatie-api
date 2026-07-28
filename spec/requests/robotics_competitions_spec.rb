require "rails_helper"

RSpec.describe "Robotics competitions", type: :request do
  let(:starts_at) { 1.hour.ago.change(usec: 0) }
  let(:result) do
    Robotics::CreateCompetition.call(
      {
        name: "Drone arena",
        slug: "drone-arena",
        starts_at: starts_at,
        duration_seconds: 20.hours,
        team_allocation_seconds: 3.hours,
        turn_duration_seconds: 10.minutes,
        claim_window_seconds: 60,
        turnover_seconds: 60
      },
      team_count: 2
    )
  end
  let(:competition) { result.competition }
  let(:first_issued) { result.issued_pins.first }
  let(:second_issued) { result.issued_pins.second }

  def path(action = nil)
    base = "/v1/robotics/competitions/#{competition.slug}"
    action ? "#{base}/#{action}" : base
  end

  def authenticate(pin)
    post path("authenticate"), params: {pin: pin}, as: :json
    response.parsed_body.fetch("token")
  end

  def team_headers(token)
    {"Authorization" => "Team #{token}"}
  end

  it "publishes the exact unauthenticated live state without PIN data" do
    get path

    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("no-store")
    payload = response.parsed_body
    expect(payload.keys).to contain_exactly(
      "server_now",
      "competition",
      "arena",
      "queue",
      "teams",
      "viewer"
    )
    expect(payload["competition"]).to include(
      "id" => competition.id,
      "slug" => "drone-arena",
      "status" => "live",
      "duration_seconds" => 20.hours.to_i,
      "turn_duration_seconds" => 10.minutes.to_i,
      "claim_window_seconds" => 60,
      "turnover_seconds" => 60
    )
    expect(payload["arena"]).to include(
      "status" => "available",
      "team_id" => nil,
      "offer_expires_at" => nil
    )
    expect(payload["viewer"]).to be_nil
    expect(payload["teams"].length).to eq(2)
    expect(response.body).not_to include(
      first_issued[:pin],
      first_issued[:team].pin_digest,
      first_issued[:team].pin_fingerprint
    )
  end

  it "authenticates a PIN with an opaque Team token and rejects bad PINs" do
    post path("authenticate"), params: {pin: "00000000"}, as: :json

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to eq(
      "error" => {
        "code" => "invalid_pin",
        "message" => "The team PIN is invalid."
      }
    )

    token = authenticate(first_issued[:pin])
    expect(token).to be_present
    expect(token).not_to eq(first_issued[:pin])
    expect { JSON.parse(token) }.to raise_error(JSON::ParserError)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.parsed_body.dig("state", "viewer", "team_id"))
      .to eq(first_issued[:team].id)
  end

  it "runs ready, claim, early stop, and turnover through state responses" do
    token = authenticate(first_issued[:pin])
    headers = team_headers(token)

    put path("readiness"),
      params: {ready: true},
      headers: headers,
      as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("arena", "status")).to eq("offered")
    expect(response.parsed_body.dig("arena", "team_id"))
      .to eq(first_issued[:team].id)
    expect(response.parsed_body.dig("viewer", "capabilities", "claim"))
      .to be(true)
    turn_id = response.parsed_body.dig("arena", "turn_id")
    expect(turn_id).to be_present

    post path("claim"),
      params: {turn_id: turn_id},
      headers: headers,
      as: :json

    expect(response).to have_http_status(:ok)
    active_state = response.parsed_body
    expect(active_state.dig("arena", "status")).to eq("active")
    expect(active_state.dig("viewer", "capabilities", "stop")).to be(true)
    expect(
      Time.iso8601(active_state.dig("arena", "session_ends_at")) -
        Time.iso8601(active_state.dig("arena", "session_started_at"))
    ).to eq(10.minutes)

    travel_to(4.minutes.from_now) do
      post path("stop"),
        params: {turn_id: turn_id},
        headers: headers,
        as: :json
    end

    expect(response).to have_http_status(:ok)
    stopped_state = response.parsed_body
    expect(stopped_state.dig("arena", "status")).to eq("turnover")
    team_state = stopped_state["teams"].find do |team|
      team["id"] == first_issued[:team].id
    end
    expect(team_state["used_seconds"]).to be_between(4.minutes, 4.minutes + 1)
    expect(team_state["remaining_seconds"])
      .to eq(team_state["allocated_seconds"] - team_state["used_seconds"])
  end

  it "keeps a persistent FIFO queue and moves a passing team to the tail" do
    first_token = authenticate(first_issued[:pin])
    second_token = authenticate(second_issued[:pin])

    put path("readiness"),
      params: {ready: true},
      headers: team_headers(first_token),
      as: :json
    put path("readiness"),
      params: {ready: true},
      headers: team_headers(second_token),
      as: :json

    expect(response.parsed_body["queue"].pluck("team_id"))
      .to eq([second_issued[:team].id])
    turn_id = response.parsed_body.dig("arena", "turn_id")

    post path("pass"),
      params: {turn_id: turn_id},
      headers: team_headers(first_token),
      as: :json

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body
    expect(payload.dig("arena", "team_id")).to eq(second_issued[:team].id)
    expect(payload["queue"].pluck("team_id")).to eq([first_issued[:team].id])
    first_team = payload["teams"].find { |item| item["id"] == first_issued[:team].id }
    expect(first_team["used_seconds"]).to eq(0)
    expect(first_team["remaining_seconds"]).to eq(3.hours.to_i)
  end

  it "requires a positive turn identifier for turn mutations" do
    token = authenticate(first_issued[:pin])
    headers = team_headers(token)
    put path("readiness"),
      params: {ready: true},
      headers: headers,
      as: :json

    post path("claim"), headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to eq(
      "error" => {
        "code" => "invalid_turn_id",
        "message" => "turn_id must be a positive integer."
      }
    )
  end

  it "requires the exact Team authorization scheme for mutations" do
    put path("readiness"), params: {ready: true}, as: :json

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body.dig("error", "code"))
      .to eq("team_authentication_required")

    put path("readiness"),
      params: {ready: true},
      headers: {"Authorization" => "Bearer invalid"},
      as: :json

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body.dig("error", "code"))
      .to eq("invalid_team_token")
  end

  it "invalidates issued tokens when an administrator regenerates the PIN" do
    token = authenticate(first_issued[:pin])
    first_issued[:team].rotate_pin!

    get path, headers: team_headers(token)

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body.dig("error", "code"))
      .to eq("invalid_team_token")
  end

  it "returns the common error envelope for missing competitions" do
    get "/v1/robotics/competitions/not-here"

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body).to eq(
      "error" => {
        "code" => "competition_not_found",
        "message" => "The robotics competition was not found."
      }
    )
  end
end
