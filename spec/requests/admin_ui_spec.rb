require "rails_helper"

RSpec.describe "RailsAdmin interface", type: :request do
  let(:admin) { create(:admin_user) }

  before do
    sign_in admin
  end

  it "renders the shared responsive admin shell" do
    get "/internal/admin"

    expect(response).to have_http_status(:ok)

    document = Nokogiri::HTML(response.body)
    expect(document.at_css('meta[name="viewport"]')["content"]).to include(
      "width=device-width"
    )
    expect(document.at_css('meta[name="robots"]')["content"]).to eq(
      "noindex, nofollow, noarchive"
    )
    expect(document.at_css("body[data-admin-shell]")).to be_present
    expect(document.at_css("[data-admin-sidebar-toggle]")).to be_present
    expect(document.at_css("[data-admin-sidebar]")).to be_present
    expect(document.at_css("[data-admin-nav-search]")).to be_present
    expect(document.at_css("#admin-main-content")).to be_present
  end

  it "renders collections as an accessible responsive data table" do
    get "/internal/admin/user"

    expect(response).to have_http_status(:ok)

    document = Nokogiri::HTML(response.body)
    expect(document.at_css(".ie-list-toolbar")).to be_present
    expect(document.at_css("table.ie-data-table")).to be_present
    record_checkbox = document.at_css('input[name="bulk_ids[]"]')
    expect(record_checkbox).to be_present
    expect(record_checkbox["aria-label"]).to include(admin.name)

    labelled_cells = document.css("tbody td[data-label]")
    expect(labelled_cells).not_to be_empty
    expect(labelled_cells).to all(satisfy { |cell| cell["data-label"].present? })
  end

  it "renders edit forms with a stable save bar and cancel action" do
    project = create(:project)

    get "/internal/admin/project/#{project.id}/edit"

    expect(response).to have_http_status(:ok)

    document = Nokogiri::HTML(response.body)
    expect(document.at_css(".ie-form-actions")).to be_present
    expect(document.at_css('.ie-form-actions button[name="_save"]')).to be_present
    expect(document.at_css('.ie-form-actions button[name="_continue"]')).to be_present
  end

  it "renders record details without nested presentation cards" do
    project = create(:project)

    get "/internal/admin/project/#{project.id}"

    expect(response).to have_http_status(:ok)

    document = Nokogiri::HTML(response.body)
    expect(document.at_css("dl.ie-detail-list")).to be_present
    expect(document.css(".ie-detail-list .card")).to be_empty
  end
end
