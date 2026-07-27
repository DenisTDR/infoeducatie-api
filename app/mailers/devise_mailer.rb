class DeviseMailer < Devise::Mailer
  self.delivery_job = DeviseMailDeliveryJob
end
