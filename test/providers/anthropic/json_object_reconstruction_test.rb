# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/active_agent/providers/anthropic_provider"

module Providers
  module Anthropic
    # On a model that accepts a prefill, with thinking off, the json_object
    # emulation prefills an assistant turn with "Here is the JSON requested:\n{"
    # and expects the model to continue from there. Reconstruction removes that
    # turn from the request and re-attaches the "{" to the last block that
    # carries `text`, skipping blocks that carry none, such as `thinking`.
    #
    # Every other request is sent without the lead-in. JsonObjectEmulationTest
    # covers both kinds of request end to end.
    class JsonObjectReconstructionTest < ActiveSupport::TestCase
      LEAD_IN = ActiveAgent::Providers::AnthropicProvider::JSON_RESPONSE_FORMAT_LEAD_IN

      def build_provider(messages: nil)
        messages ||= [
          { role: "user", content: "Return JSON." },
          { role: "assistant", content: LEAD_IN }
        ]

        provider = ActiveAgent::Providers::AnthropicProvider.new(
          service:  "Anthropic",
          model:    "claude-sonnet-4-5",
          messages: messages
        )

        # `prompt` normally does this; set it directly to exercise the
        # reconstruction without issuing a request. Messages are assigned a
        # second time because the cast normalizes string content into text
        # blocks, while the real flow assigns the lead-in verbatim from
        # `prepare_prompt_request` — and the guard keys off that raw string.
        provider.request = provider.class.prompt_request_type.cast(messages: messages)
        provider.request.messages = messages
        provider
      end

      test "re-attaches the brace to the text block when thinking comes first" do
        response = {
          content: [
            { type: "thinking", thinking: "The user wants a currency code." },
            { type: "text", text: "\"currency_code\":\"USD\"}" }
          ]
        }

        build_provider.send(:process_prompt_finished_extract_messages, response)

        assert_equal "The user wants a currency code.", response[:content][0][:thinking]
        assert_equal "{\"currency_code\":\"USD\"}", response[:content][1][:text]
      end

      test "the reconstructed text parses as JSON" do
        response = {
          content: [
            { type: "thinking", thinking: "reasoning" },
            { type: "text", text: "\"currency_code\":\"USD\"}" }
          ]
        }

        build_provider.send(:process_prompt_finished_extract_messages, response)

        text = response[:content].last[:text]
        assert_equal({ "currency_code" => "USD" }, JSON.parse(text))
      end

      test "still re-attaches the brace when the text block is first" do
        response = { content: [ { type: "text", text: "\"currency_code\":\"USD\"}" } ] }

        build_provider.send(:process_prompt_finished_extract_messages, response)

        assert_equal "{\"currency_code\":\"USD\"}", response[:content][0][:text]
      end

      test "prefers the last text block when a response carries several" do
        response = {
          content: [
            { type: "thinking", thinking: "reasoning" },
            { type: "text", text: "preamble" },
            { type: "text", text: "\"currency_code\":\"USD\"}" }
          ]
        }

        build_provider.send(:process_prompt_finished_extract_messages, response)

        assert_equal "preamble", response[:content][1][:text]
        assert_equal "{\"currency_code\":\"USD\"}", response[:content][2][:text]
      end

      test "removes the lead-in message from the request" do
        provider = build_provider

        provider.send(:process_prompt_finished_extract_messages, { content: [ { type: "text", text: "{}" } ] })

        assert_equal 1, provider.send(:request).messages.size
        assert_equal :user, provider.send(:request).messages.last.role.to_sym
      end

      test "leaves the response alone when the request was not prefilled" do
        provider = build_provider(messages: [ { role: "user", content: "Return JSON." } ])
        response = { content: [ { type: "text", text: "{\"currency_code\":\"USD\"}" } ] }

        provider.send(:process_prompt_finished_extract_messages, response)

        assert_equal "{\"currency_code\":\"USD\"}", response[:content][0][:text]
      end

      test "does not raise when the response carries no text block" do
        response = { content: [ { type: "thinking", thinking: "no answer yet" } ] }

        assert_nothing_raised do
          build_provider.send(:process_prompt_finished_extract_messages, response)
        end
      end
    end
  end
end
