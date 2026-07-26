class Users::PasswordsController < Devise::PasswordsController
  include AuthenticationLocale

  layout "authentication"
end
