require "rails_helper"

RSpec.describe "RailsAdmin robotics management", type: :request do
  let(:admin) { create(:admin_user) }

  before do
    sign_in admin
  end

  it "creates a competition with friendly units and displays five PINs once" do
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

    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("no-store")
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
    expect(response.body.scan(/\b\d{8}\b/).uniq.length).to be >= 5
    expect(response.body).to include(
      "#{Settings.ui.url.to_s.delete_suffix("/")}/robotica/robotica-2026"
    )
  end

  it "records signed time changes with a mandatory reason and actor" do
    team = create(:robotics_team)

    post "/internal/admin/robotics_team/#{team.id}/adjust_robotics_team_time",
      params: {
        time_adjustment: {
          minutes: -15,
          reason: "Safety penalty"
        }
      }

    expect(response).to have_http_status(:redirect)
    entry = team.robotics_time_entries
      .where(kind: RoboticsTimeEntry::ADMIN_ADJUSTMENT)
      .last
    expect(entry).to have_attributes(
      amount_seconds: -15.minutes.to_i,
      reason: "Safety penalty",
      actor: admin
    )
    expect(team.balance_seconds).to eq(165.minutes.to_i)
  end

  it "regenerates a PIN only on POST and invalidates existing tokens" do
    team = create(:robotics_team)
    token = Robotics::TeamToken.issue(team)

    get "/internal/admin/robotics_team/#{team.id}/regenerate_robotics_team_pin"
    expect(response).to have_http_status(:ok)
    expect(team.reload.authentication_version).to eq(0)

    post "/internal/admin/robotics_team/#{team.id}/regenerate_robotics_team_pin"
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.body).to match(/\b\d{8}\b/)
    expect(team.reload.authentication_version).to eq(1)
    expect(
      Robotics::TeamToken.authenticate(
        token,
        competition: team.robotics_competition
      )
    ).to be_nil
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

    travel_to(2.minutes.from_now) do
      post "/internal/admin/robotics_turn/#{turn.id}/force_stop_robotics_turn",
        params: {force_stop: {reason: "Arena safety stop"}}
    end

    expect(response).to have_http_status(:redirect)
    expect(turn.reload).to have_attributes(
      state: "turnover",
      charged_seconds: 2.minutes.to_i,
      stop_reason: "Arena safety stop",
      stopped_by: admin
    )
  end

  it "keeps turn and ledger history read-only in RailsAdmin" do
    team = create(:robotics_team)
    entry = team.robotics_time_entries.first

    expect {
      get "/internal/admin/robotics_time_entry/#{entry.id}/edit"
    }.to raise_error(RailsAdmin::ActionNotAllowed)
  end
end
