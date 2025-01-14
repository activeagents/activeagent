# frozen_string_literal: true

require "base64"

module ActiveAgent
  # = Active Agent \InlinePreviewInterceptor
  #
  # Implements a agent preview interceptor that converts image tag src attributes
  # that use inline cid: style URLs to data: style URLs so that they are visible
  # when previewing an HTML prompt in a web browser.
  #
  # This interceptor is enabled by default. To disable it, delete it from the
  # <tt>ActiveAgent::Base.preview_interceptors</tt> array:
  #
  #   ActiveAgent::Base.preview_interceptors.delete(ActiveAgent::InlinePreviewInterceptor)
  #
  class InlinePreviewInterceptor
    PATTERN = /src=(?:"cid:[^"]+"|'cid:[^']+')/i

    include Base64

    def self.previewing_prompt(context) # :nodoc:
      new(context).transform!
    end

    def initialize(context) # :nodoc:
      @context = context
    end

    def transform! # :nodoc:
      return context if html_part.blank?

      html_part.body = html_part.decoded.gsub(PATTERN) do |match|
        if (part = find_part(match[9..-2]))
          %(src="#{data_url(part)}")
        else
          match
        end
      end

      context
    end

    private

    attr_reader :context

    def html_part
      @html_part ||= context.html_part
    end

    def data_url(part)
      "data:#{part.mime_type};base64,#{strict_encode64(part.body.raw_source)}"
    end

    def find_part(cid)
      if (part = context.all_parts.find { |p| p.attachment? && p.cid == cid })
        %(src="#{data_url(part)}")
      else
        match
      end
    end
  end
end
