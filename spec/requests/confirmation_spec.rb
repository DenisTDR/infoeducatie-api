require "rails_helper"

RSpec.describe "User confirmation", type: :request do
  it "confirms the user and redirects to the configured frontend" do
    user = create(:user)
    raw_token, encrypted_token = Devise.token_generator.generate(
      User,
      :confirmation_token
    )
    user.update_columns(
      confirmation_token: encrypted_token,
      confirmation_sent_at: Time.current
    )

    get "/users/confirmation", params: {confirmation_token: raw_token}

    expect(response).to redirect_to("#{Settings.ui.url}/?login=true")
    expect(user.reload).to be_confirmed
  end
end
