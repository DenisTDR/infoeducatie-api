require "rails_helper"

RSpec.describe "RailsAdmin robotics management", type: :request do
  let(:admin) { create(:admin_user) }

  before do
    sign_in admin
  end

  it "creates a competition with friendly units and displays five PINs once" do
    get "/internal/admin/robotics_competition/create_robotics_competition"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("data-robotics-competition-form")
    expect(response.body).to include("data-robotics-competition-name")
    expect(response.body).to include("data-robotics-competition-slug")

    expect {
      post "/internal/admin/robotics_competition/create_robotics_competition",
        params: {
          robotics_competition: {
            name: "Robotica 2026",
            slug: "",
            starts_at: 1.day.from_now.strftime("%Y-%m-%dT%H:%M"),
            duration_hours: 20,
            team_count: 5,
            team_allocation_minutes: 180,
            turn_duration_minutes: 10,
            claim_window_seconds: 60,
            turnover_seconds: 60
          }
        }
    }.to change(RoboticsCompetition, :count).by(1)
      .and change(RoboticsTeam, :count).by(5)
      .and change(RoboticsTimeEntry, :count).by(5)

    expect(response).to have_http_status(:see_other)
    competition = RoboticsCompetition.order(:id).last
    expect(competition).to have_attributes(
      slug: "robotica-2026",
      duration_seconds: 20.hours.to_i,
      team_allocation_seconds: 180.minutes.to_i,
      turn_duration_seconds: 10.minutes.to_i,
      claim_window_seconds: 60,
      turnover_seconds: 60
    )
    expect(competition.robotics_teams.order(:position).pluck(:name))
      .to eq(["Echipa 1", "Echipa 2", "Echipa 3", "Echipa 4", "Echipa 5"])

    follow_redirect!

    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.body).to include(
      'content="no-cache" name="turbo-cache-control"'
    )
    expect(response.body.scan(/\b\d{8}\b/).uniq.length).to be >= 5
    expect(response.body).to include(
      "#{Settings.ui.url.to_s.delete_suffix("/")}/robotica/robotica-2026"
    )
    expect(response.body).to include('target="_blank"')
    expect(response.body).to include('rel="noopener noreferrer"')

    issued_pins = response.body.scan(/\b\d{8}\b/).uniq
    get "/internal/admin/robotics_competition/create_robotics_competition"
    expect(response).to have_http_status(:ok)
    issued_pins.each do |pin|
      expect(response.body).not_to include(pin)
    end
  end

  it "preserves a manually supplied competition slug" do
    post "/internal/admin/robotics_competition/create_robotics_competition",
      params: {
        robotics_competition: {
          name: "Robotica 2026",
          slug: "arena-drone",
          starts_at: 1.day.from_now.strftime("%Y-%m-%dT%H:%M"),
          duration_hours: 20,
          team_count: 1,
          team_allocation_minutes: 180,
          turn_duration_minutes: 10,
          claim_window_seconds: 60,
          turnover_seconds: 60
        }
      }

    expect(response).to have_http_status(:see_other)
    expect(RoboticsCompetition.order(:id).last.slug).to eq("arena-drone")
  end

  it "redirects the maximum 20-team PIN sheet without overflowing the session" do
    post "/internal/admin/robotics_competition/create_robotics_competition",
      params: {
        robotics_competition: {
          name: "Robotica 20 echipe",
          slug: "",
          starts_at: 1.day.from_now.strftime("%Y-%m-%dT%H:%M"),
          duration_hours: 20,
          team_count: 20,
          team_allocation_minutes: 180,
          turn_duration_minutes: 10,
          claim_window_seconds: 60,
          turnover_seconds: 60
        }
      }

    expect(response).to have_http_status(:see_other)
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(response.body.scan(/\b\d{8}\b/).uniq.length).to be >= 20
  end

  it "renders validation feedback without redirecting" do
    expect {
      post "/internal/admin/robotics_competition/create_robotics_competition",
        params: {
          robotics_competition: {
            name: "",
            slug: "",
            starts_at: 1.day.from_now.strftime("%Y-%m-%dT%H:%M"),
            duration_hours: 20,
            team_count: 5,
            team_allocation_minutes: 180,
            turn_duration_minutes: 10,
            claim_window_seconds: 60,
            turnover_seconds: 60
          }
        }
    }.not_to change(RoboticsCompetition, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("Competition could not be created.")
    expect(response.body).to include("Name can&#39;t be blank")
  end

  it "records signed time changes with a mandatory reason and actor" do
    team = create(:robotics_team)
    action_path =
      "/internal/admin/robotics_team/#{team.id}/adjust_robotics_team_time"

    get action_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Adjust time for")

    post action_path,
      params: {
        time_adjustment: {
          minutes: -15,
          reason: "Safety penalty"
        }
      }

    expect(response).to have_http_status(:see_other)
    entry = team.robotics_time_entries
      .where(kind: RoboticsTimeEntry::ADMIN_ADJUSTMENT)
      .last
    expect(entry).to have_attributes(
      amount_seconds: -15.minutes.to_i,
      reason: "Safety penalty",
      actor: admin
    )
    expect(team.balance_seconds).to eq(165.minutes.to_i)

    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Deducted 15 minutes")
  end

  it "preserves time adjustment feedback and fields after validation fails" do
    team = create(:robotics_team)
    action_path =
      "/internal/admin/robotics_team/#{team.id}/adjust_robotics_team_time"

    expect {
      post action_path,
        params: {
          time_adjustment: {
            minutes: -999,
            reason: "Requested correction"
          }
        }
    }.not_to change {
      team.robotics_time_entries
        .where(kind: RoboticsTimeEntry::ADMIN_ADJUSTMENT)
        .count
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include(
      "The deduction exceeds the team&#39;s remaining time."
    )
    expect(response.body).to include('value="-999"')
    expect(response.body).to include("Requested correction")
  end

  it "regenerates a PIN through a one-time redirect result" do
    team = create(:robotics_team)
    token = Robotics::TeamToken.issue(team)
    action_path =
      "/internal/admin/robotics_team/#{team.id}/regenerate_robotics_team_pin"

    get action_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Regenerate PIN?")
    expect(response.body).not_to include("issued-robotics-pin")
    expect(team.reload.authentication_version).to eq(0)

    post action_path,
      headers: {
        "Accept" => "text/vnd.turbo-stream.html, text/html"
      }
    expect(response).to have_http_status(:see_other)
    expect(response.location).to end_with(action_path)
    expect(response.body).not_to include("issued-robotics-pin")
    expect(team.reload.authentication_version).to eq(1)
    expect(
      Robotics::TeamToken.authenticate(
        token,
        competition: team.robotics_competition
      )
    ).to be_nil

    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.headers["Pragma"]).to eq("no-cache")
    expect(response.body).to include(
      'content="no-cache" name="turbo-cache-control"'
    )
    pin_match = response.body.match(
      /id="issued-robotics-pin".*?value="(\d{8})"/m
    )
    expect(pin_match).to be_present
    new_pin = pin_match[1]
    expect(
      RoboticsTeam.authenticate_pin(team.robotics_competition, new_pin)
    ).to eq(team)

    get action_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Regenerate PIN?")
    expect(response.body).not_to include("issued-robotics-pin")
    expect(response.body).not_to include(new_pin)
    expect(team.reload.authentication_version).to eq(1)
  end

  it "force-stops an active turn, charges elapsed time, and records the admin" do
    competition = create(:robotics_competition, starts_at: 1.hour.ago)
    team = create(:robotics_team, robotics_competition: competition)
    now = Time.current.change(usec: 0)
    Robotics::CompetitionCoordinator.set_readiness!(
      competition,
      team: team,
      ready: true,
      now: now
    )
    turn = competition.robotics_turns.live_lease.first
    Robotics::CompetitionCoordinator.claim!(
      competition,
      team: team,
      turn_id: turn.id,
      now: now
    )
    action_path =
      "/internal/admin/robotics_turn/#{turn.id}/force_stop_robotics_turn"

    get action_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Force-stop")

    travel_to(2.minutes.from_now) do
      post action_path,
        params: {force_stop: {reason: "Arena safety stop"}}
    end

    expect(response).to have_http_status(:see_other)
    expect(turn.reload).to have_attributes(
      state: "turnover",
      charged_seconds: 2.minutes.to_i,
      stop_reason: "Arena safety stop",
      stopped_by: admin
    )

    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("The active robotics turn was stopped.")
  end

  it "shows non-actionable feedback if a turn expires before force-stop" do
    competition = create(:robotics_competition, starts_at: 1.hour.ago)
    team = create(:robotics_team, robotics_competition: competition)
    now = Time.current.change(usec: 0)
    Robotics::CompetitionCoordinator.set_readiness!(
      competition,
      team: team,
      ready: true,
      now: now
    )
    turn = competition.robotics_turns.live_lease.first
    Robotics::CompetitionCoordinator.claim!(
      competition,
      team: team,
      turn_id: turn.id,
      now: now
    )

    travel_to(now + competition.turn_duration_seconds + 2.minutes) do
      post(
        "/internal/admin/robotics_turn/#{turn.id}/force_stop_robotics_turn",
        params: {force_stop: {reason: "Stale confirmation"}}
      )
    end

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include(
      "Only an active testing turn can be force-stopped."
    )
    expect(response.body).to include("Back to robotics turns")
    expect(response.body).not_to include("Force-stop turn")
    expect(turn.reload).not_to be_active
    expect(turn.robotics_time_entry).to be_present
  end

  it "renders the complete robotics admin surface without missing copy" do
    competition = create(:robotics_competition, starts_at: 1.day.from_now)
    team = create(:robotics_team, robotics_competition: competition)
    paths = [
      "/internal/admin/robotics_competition",
      "/internal/admin/robotics_competition/#{competition.id}",
      "/internal/admin/robotics_competition/#{competition.id}/edit",
      "/internal/admin/robotics_competition/create_robotics_competition",
      "/internal/admin/robotics_team",
      "/internal/admin/robotics_team/#{team.id}",
      "/internal/admin/robotics_team/#{team.id}/edit",
      "/internal/admin/robotics_team/#{team.id}/adjust_robotics_team_time",
      "/internal/admin/robotics_team/#{team.id}/regenerate_robotics_team_pin",
      "/internal/admin/robotics_turn",
      "/internal/admin/robotics_time_entry"
    ]

    paths.each do |path|
      get path
      expect(response).to have_http_status(:ok), path
      expect(response.body).not_to include("Translation missing"), path
    end

    get "/internal/admin/robotics_competition/#{competition.id}/edit"
    expect(response.body).to include(
      'name="robotics_competition[duration_hours]"'
    )
    expect(response.body).to include(
      'name="robotics_competition[turn_duration_minutes]"'
    )
    expect(response.body).not_to include(
      'name="robotics_competition[team_allocation_seconds]"'
    )
  end

  it "updates scheduled competition timing with friendly admin units" do
    competition = create(:robotics_competition, starts_at: 1.day.from_now)

    put "/internal/admin/robotics_competition/#{competition.id}/edit",
      params: {
        robotics_competition: {
          name: "Updated robotics competition",
          slug: "updated-robotics-competition",
          duration_hours: "18.5",
          turn_duration_minutes: "12",
          claim_window_seconds: "45",
          turnover_seconds: "30"
        }
      }

    expect(response).to have_http_status(:redirect)
    expect(competition.reload).to have_attributes(
      name: "Updated robotics competition",
      slug: "updated-robotics-competition",
      duration_seconds: 18.5.hours.to_i,
      turn_duration_seconds: 12.minutes.to_i,
      claim_window_seconds: 45,
      turnover_seconds: 30
    )
  end

  it "keeps robotics history and secret-bearing exports unavailable" do
    team = create(:robotics_team)
    entry = team.robotics_time_entries.first
    turn = team.robotics_turns.create!(
      robotics_competition: team.robotics_competition,
      sequence_number: 1,
      state: "passed",
      offered_at: Time.current,
      offer_expires_at: 1.minute.from_now,
      ended_at: Time.current,
      stop_reason: "Test history"
    )

    unavailable_action = proc do |&request|
      error = begin
        request.call
        nil
      rescue StandardError => raised_error
        raised_error
      end

      if error
        expect(error.class.name).to eq("RailsAdmin::ActionNotAllowed")
      else
        expect(response).not_to have_http_status(:success)
      end
    end

    unavailable_action.call do
      get "/internal/admin/robotics_time_entry/#{entry.id}/edit"
    end

    unavailable_action.call do
      get "/internal/admin/robotics_turn/#{turn.id}/edit"
    end

    unavailable_action.call do
      get "/internal/admin/robotics_team/export"
    end

    unavailable_action.call do
      get "/internal/admin/robotics_competition/export"
    end
  end
end
