require "rails_helper"

RSpec.describe "Admin authentication", type: :request do
  def document
    Nokogiri::HTML(response.body)
  end

  describe "GET /v1/users/sign_in" do
    before { get "/v1/users/sign_in" }

    it "renders the branded authentication layout" do
      expect(response).to have_http_status(:ok)
      expect(document.at_css("body.auth-page")).to be_present
      expect(document.at_css("html")["lang"]).to eq("ro")
      expect(document.at_css("title").text).to eq(
        "Autentificare | InfoEducație Admin"
      )
      expect(document.at_css(".auth-brand__image")["src"]).to include(
        "admin-login"
      )
    end

    it "uses accessible password-manager friendly fields" do
      form = document.at_css("form.auth-form")

      expect(form["action"]).to eq("/v1/users/sign_in")
      expect(form.at_css("input[name='user[email]']")["autocomplete"]).to eq(
        "username"
      )
      expect(form.at_css("input[name='user[password]']")["autocomplete"]).to eq(
        "current-password"
      )
      expect(form.at_css("input[name='user[remember_me]']")).to be_present
      expect(form.at_css("input[type='submit']")["value"]).to eq(
        "Autentificare"
      )
    end

    it "shows recovery actions without inviting public registration" do
      expect(document.at_css("a[href='/users/password/new']")).to be_present
      expect(document.at_css("a[href='/users/confirmation/new']")).to be_present
      expect(document.at_css("a[href='/v1/users']")).to be_nil
    end
  end

  it "redirects unauthenticated RailsAdmin requests to the branded login" do
    get "/internal/admin"

    expect(response).to redirect_to("/v1/users/sign_in")

    follow_redirect!

    expect(response).to have_http_status(:ok)
    expect(document.at_css("body.auth-page")).to be_present
    expect(response.body).to include(
      I18n.t("devise.failure.unauthenticated", locale: :ro)
    )
  end

  it "uses the authentication layout for password recovery" do
    get "/users/password/new"

    expect(response).to have_http_status(:ok)
    expect(document.at_css("body.auth-page")).to be_present
    expect(document.at_css("h1").text).to eq("Resetează parola")
  end

  it "uses the authentication layout for confirmation recovery" do
    get "/users/confirmation/new"

    expect(response).to have_http_status(:ok)
    expect(document.at_css("body.auth-page")).to be_present
    expect(document.at_css("h1").text).to eq("Retrimite instrucțiunile")
  end
end
