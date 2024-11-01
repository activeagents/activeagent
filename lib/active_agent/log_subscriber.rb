# # frozen_string_literal: true

# require "active_support/log_subscriber"

# module ActiveAgent
#   # = Active Agent \LogSubscriber
#   #
#   # Implements the ActiveSupport::LogSubscriber for logging notifications when
#   # prompt is generated.
#   class LogSubscriber < ActiveSupport::LogSubscriber
#     # A prompt was generated.
#     def deliver(event)
#       info do
#         if exception = event.payload[:exception_object]
#           "Failed delivery of prompt #{event.payload[:message_id]} error_class=#{exception.class} error_message=#{exception.message.inspect}"
#         elsif event.payload[:perform_deliveries]
#           "Generated response for prompt #{event.payload[:message_id]} (#{event.duration.round(1)}ms)"
#         else
#           "Skipped generation of prompt #{event.payload[:message_id]} as `perform_generation` is false"
#         end
#       end

#       debug { event.payload[:mail] }
#     end
#     subscribe_log_level :deliver, :debug

#     # An email was generated.
#     def process(event)
#       debug do
#         agent = event.payload[:agent]
#         action = event.payload[:action]
#         "#{agent}##{action}: processed outbound mail in #{event.duration.round(1)}ms"
#       end
#     end
#     subscribe_log_level :process, :debug

#     # Use the logger configured for ActionMailer::Base.
#     def logger
#       ActionMailer::Base.logger
#     end
#   end
# end

# ActionMailer::LogSubscriber.attach_to :action_mailer
