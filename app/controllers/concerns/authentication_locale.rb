module AuthenticationLocale
  extend ActiveSupport::Concern

  included do
    around_action :with_authentication_locale
  end

  private

  def with_authentication_locale(&action)
    requested_locale = params[:locale].to_s
    available_locale = I18n.available_locales.find do |locale|
      locale.to_s == requested_locale
    end

    I18n.with_locale(available_locale || :ro, &action)
  end
end
