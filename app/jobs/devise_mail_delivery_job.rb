require "net/smtp"

class DeviseMailDeliveryJob < ActionMailer::MailDeliveryJob
  TRANSIENT_DELIVERY_ERRORS = [
    Net::OpenTimeout,
    Net::ReadTimeout,
    Net::SMTPServerBusy,
    Timeout::Error,
    SocketError,
    EOFError,
    Errno::ECONNREFUSED,
    Errno::ECONNRESET,
    Errno::EHOSTUNREACH
  ].freeze

  self.log_arguments = false

  retry_on(
    *TRANSIENT_DELIVERY_ERRORS,
    wait: :polynomially_longer,
    attempts: 5
  ) do |job, error|
    Rails.logger.error(
      "Devise email delivery failed after #{job.executions} attempts " \
      "(#{error.class}): #{error.message}"
    )

    Sentry.capture_exception(
      error,
      tags: {
        component: "devise_email_delivery",
        job_id: job.job_id
      }
    ) if defined?(Sentry) && Sentry.initialized?
  end
end
