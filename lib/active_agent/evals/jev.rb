# frozen_string_literal: true

# Loaded by an explicit `require "active_agent/evals/jev"` — never by
# `require "active_agent/evals"` — so a host that grades with an ordinary
# language model never carries a second vendor's client.
require "net/http"
require "json"
require "uri"
require_relative "../evals"

module ActiveAgent
  module Evals
    # A Judge whose bounded decisions are answered by Jev, TypeSafe AI's
    # "System One" model. Jev generates no text: a request carries a `state`
    # (the text to judge) and named questions — a Score on a scale, a Choice
    # over options — and the answer is one structured decision per question
    # with a calibrated probability behind it, billed on input tokens only.
    #
    # Of the three calls a Judge serves, two end in such a decision and become
    # Jev questions: `:score` is one Score question over the gem's own scoring
    # prompt, and `:verdict`'s winner is one Choice over the compared model
    # labels. The language tasks — the verdict's rationale and the whole of
    # `:recommend` — go to `text_judge`, an ordinary Judge, when one is given;
    # without one the rationale is a sentence naming Jev's probability and a
    # recommendation is nil, which the runner treats as "no recommendation"
    # rather than a failure. That is the hybrid pattern the DeepEval and
    # Langfuse integrations settled on: the language model explains, Jev
    # decides.
    #
    #   require "active_agent/evals/jev"
    #
    #   judge = ActiveAgent::Evals::Jev.judge(
    #     label: "jev-latest",
    #     text_judge: ActiveAgent::Evals::Judge.new(label: "claude-haiku-4-5") { |instructions:, prompt:| ... }
    #   )
    #
    #   ActiveAgent::Evals::Runner.new(scenarios:, models:, replay:, judge: judge).call
    #
    # The wire format is Client's alone, and it is assumed rather than
    # confirmed: read its doc comment before touching a field name.
    module Jev
      DEFAULT_BASE_URL = "https://api.typesafe.ai"
      DEFAULT_MODEL = "jev-latest"
      API_KEY_ENV = "TYPESAFE_API_KEY"

      # The one question each kind asks. The criterion or task, the user's
      # message and the answer are all in the state, the gem's own prompt.
      SCORE_QUESTION = "How well does the assistant's answer satisfy the criterion or task set out above, " \
                       "from 0 (fails completely) to 1 (fully satisfies)?"
      VERDICT_QUESTION = "Which model best accomplishes the agent's goals, weighing task completion first " \
                         "and cost and latency second?"

      # Judge#verdict lists one line per compared model under this heading,
      # each opening with the model's label; the labels are the Choice's options.
      RESULTS_HEADING = "Results per model:"
      RESULT_LINE = /\A(.+?): pass rate /

      # Raised by Client for anything that is not a usable answer: the endpoint
      # unreachable, a rejection, a body that is not JSON. Judge#ask turns it
      # into a nil answer and a warning, so a run degrades to rule scoring.
      class Error < StandardError; end

      # One decision: its value, Jev's calibrated probability and confidence
      # for it, and what the call cost in input tokens.
      Answer = Struct.new(:value, :probability, :confidence, :input_tokens, :model, keyword_init: true)

      class << self
        # Builds a Judge that sends its bounded decisions to Jev.
        #
        # @param label [String] how reports name the judge
        # @param api_key [String, nil] defaults to `TYPESAFE_API_KEY`
        # @param model [String] `jev-latest`, `jev-1.13` or `jev-preview`
        # @param base_url [String] where `/v1/systemone` is posted; a host can route elsewhere
        # @param text_judge [Judge, nil] answers `:recommend` and writes the verdict's rationale
        # @param on_usage [#call, nil] called after each answered Jev call with
        #   `{ "kind", "model", "input_tokens", "output_tokens", "cost" }`; output
        #   tokens are always 0 and the cost nil, since nothing is generated and
        #   the price per input token is not yet known. An error it raises is
        #   logged, not propagated, so bookkeeping never costs a grade
        # @return [Judge]
        # @raise [ArgumentError] without a key
        def judge(label:, api_key: nil, model: DEFAULT_MODEL, base_url: DEFAULT_BASE_URL, text_judge: nil, on_usage: nil)
          client = Client.new(api_key: api_key.presence || ENV[API_KEY_ENV], model: model, base_url: base_url)

          Judge.new(label: label) do |instructions:, prompt:, kind:|
            case kind
            when :score then score(client, prompt, on_usage)
            when :verdict then verdict(client, text_judge, instructions, prompt, on_usage)
            else delegate(text_judge, instructions, prompt, kind)
            end
          end
        end

        private

        def score(client, prompt, on_usage)
          answer = client.score(prompt, SCORE_QUESTION)
          report_usage(on_usage, :score, answer)
          JSON.generate("score" => answer.value)
        end

        def verdict(client, text_judge, instructions, prompt, on_usage)
          labels = compared_labels(prompt)
          return nil if labels.empty?

          answer = client.choose(prompt, VERDICT_QUESTION, labels)
          report_usage(on_usage, :verdict, answer)
          winner = answer.value.to_s
          # Judge#verdict discards an unknown winner itself; stopping here
          # spares the text judge a rationale nobody will read.
          return nil unless labels.include?(winner)

          JSON.generate("winner" => winner, "rationale" => rationale(text_judge, instructions, prompt, answer))
        end

        # The labels on the lines under the results heading, up to the blank
        # line that ends them, in the order the prompt lists them.
        def compared_labels(prompt)
          section = prompt.to_s.split(RESULTS_HEADING, 2)[1].to_s.split(/\n[ \t]*\n/, 2)[0].to_s
          section.lines.filter_map { |line| line[RESULT_LINE, 1]&.strip.presence }
        end

        def rationale(text_judge, instructions, prompt, answer)
          written = parse_object(delegate(text_judge, instructions, prompt, :verdict))&.dig("rationale")
          return written if written.is_a?(String) && written.present?

          answer.probability ? "Chosen by Jev with probability #{format('%.2f', answer.probability)}." : "Chosen by Jev."
        end

        # Judge#ask is private, but it is the one place that forwards `kind:`
        # only to a block that names it and turns a failure into nil with a
        # warning — the behaviour a delegated call must keep — so it is reused
        # rather than copied.
        def delegate(text_judge, instructions, prompt, kind)
          text_judge&.send(:ask, instructions, prompt, kind)
        end

        def report_usage(callback, kind, answer)
          return unless callback

          callback.call(
            "kind" => kind.to_s, "model" => answer.model, "input_tokens" => answer.input_tokens,
            "output_tokens" => 0, "cost" => nil
          )
        rescue StandardError => e
          warn_failure("judge on_usage callback failed: #{e.class}")
        end

        def parse_object(content)
          json = content.to_s[/\{.*\}/m]
          parsed = JSON.parse(json) if json
          parsed if parsed.is_a?(Hash)
        rescue JSON::ParserError
          nil
        end

        def warn_failure(message)
          message = "[ActiveAgent::Evals] #{message}"
          if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
            Rails.logger.warn(message)
          else
            warn(message)
          end
        end
      end

      # The wire format, in one place. Jev's official reference was not
      # reachable when this was written, so the request and the response below
      # are what the DeepEval and Langfuse integrations and the third-party SDK
      # READMEs agree on, and nothing outside this class reads a field of
      # either. A mismatch against the real API is a fix here.
      #
      # Request, `POST {base_url}/v1/systemone` with `Authorization: Bearer <key>`:
      #
      #   { "model": "jev-latest",
      #     "state": "<the text to judge>",
      #     "questions": {
      #       "score":  { "type": "score",  "question": "...", "min": 0, "max": 1 },
      #       "winner": { "type": "choice", "question": "...", "options": ["gpt-5-mini", "qwen3:8b"] } } }
      #
      # Response, one answer per question under its name, with usage optional:
      #
      #   { "model": "jev-1.13",
      #     "answers": { "score": { "value": 0.83, "probability": 0.81, "confidence": 0.9 } },
      #     "usage": { "input_tokens": 412 } }
      #
      # Reading is tolerant on purpose — the answer under `answers`, `results`
      # or the top level, as an object or a bare value; the value under
      # `value`, `score`, `choice`, `answer` or `decision`; usage under either
      # token spelling — so a renamed field is read rather than raised on. That
      # tolerance stays in here.
      class Client
        PATH = "/v1/systemone"
        # The Score question's bounds; its answer is normalised to 0.0..1.0 by them.
        SCORE_MIN = 0
        SCORE_MAX = 1
        ANSWER_SECTIONS = %w[answers results].freeze
        VALUE_KEYS = %w[value score choice answer decision].freeze
        PROBABILITY_KEYS = %w[probability calibrated_probability].freeze
        CONFIDENCE_KEYS = %w[confidence].freeze
        INPUT_TOKEN_KEYS = %w[input_tokens prompt_tokens tokens].freeze

        attr_reader :model, :endpoint

        def initialize(api_key:, model: DEFAULT_MODEL, base_url: DEFAULT_BASE_URL, open_timeout: 10, timeout: 60)
          raise ArgumentError, "Jev.judge needs an api_key:, or #{API_KEY_ENV} in the environment" if api_key.blank?

          @api_key = api_key
          @model = model.to_s
          @endpoint = URI.parse("#{base_url.to_s.chomp('/')}#{PATH}")
          @open_timeout = open_timeout
          @timeout = timeout
        end

        # One Score question over `state`; the answer's value is 0.0..1.0.
        def score(state, question)
          answer = ask(state, "score", "type" => "score", "question" => question, "min" => SCORE_MIN, "max" => SCORE_MAX)
          value = number(answer.value)
          raise Error, "#{where} answered the score question without a number" if value.nil?

          answer.value = ((value - SCORE_MIN) / (SCORE_MAX - SCORE_MIN).to_f).clamp(0.0, 1.0)
          answer
        end

        # One Choice question over `state`; the answer's value is the chosen option as sent.
        def choose(state, question, options)
          ask(state, "winner", "type" => "choice", "question" => question, "options" => options)
        end

        private

        def ask(state, name, question)
          body = parse(post(JSON.generate("model" => @model, "state" => state, "questions" => { name => question })))
          decision = answer_for(body, name)
          raise Error, "#{where} answered without a decision for #{name}" if decision.nil?

          decision = { "value" => decision } unless decision.is_a?(Hash)
          reported = body["model"]
          Answer.new(
            value: first(decision, VALUE_KEYS),
            probability: number(first(decision, PROBABILITY_KEYS)),
            confidence: number(first(decision, CONFIDENCE_KEYS)),
            input_tokens: input_tokens(body),
            model: reported.is_a?(String) && reported.present? ? reported : @model
          )
        end

        # The answer under the question's name, wherever the body keeps it:
        # a map keyed by name, a list of named entries, or the top level.
        def answer_for(body, name)
          ANSWER_SECTIONS.each do |section|
            answers = body[section]
            found =
              if answers.is_a?(Hash)
                answers[name]
              else
                Array(answers).find { |entry| entry.is_a?(Hash) && [ entry["name"], entry["question"] ].include?(name) }
              end
            return found unless found.nil?
          end
          body[name]
        end

        def input_tokens(body)
          usage = body["usage"]
          count = first(usage, INPUT_TOKEN_KEYS) if usage.is_a?(Hash)
          count.to_i if count.is_a?(Numeric)
        end

        def first(hash, keys)
          key = keys.find { |candidate| hash.key?(candidate) }
          hash[key] if key
        end

        def number(value)
          return value.to_f if value.is_a?(Numeric) && value.finite?

          Float(value, exception: false) if value.is_a?(String)
        end

        def post(body)
          http = Net::HTTP.new(@endpoint.hostname, @endpoint.port)
          http.use_ssl = @endpoint.scheme == "https"
          http.open_timeout = @open_timeout
          http.read_timeout = @timeout
          http.write_timeout = @timeout
          request = Net::HTTP::Post.new(@endpoint.request_uri)
          request["Authorization"] = "Bearer #{@api_key}"
          request["Content-Type"] = "application/json"
          request["Accept"] = "application/json"
          request.body = body
          http.request(request)
        rescue Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError => e
          # These messages can quote the response's status line, headers or body.
          raise Error.new("#{where} returned a malformed response (#{e.class})"), cause: nil
        rescue IOError, SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError => e
          raise Error, "#{where} could not be reached (#{e.class}: #{e.message})"
        end

        # The response as a JSON object. A rejection names the status and never
        # the body, which could quote the request; a 401 or 403 says what to check.
        def parse(response)
          status = response.code.to_i
          raise Error, "#{where} rejected the request (HTTP #{status}); check #{API_KEY_ENV}" if [ 401, 403 ].include?(status)
          raise Error, "#{where} returned HTTP #{status}" unless (200..299).cover?(status)

          parsed = JSON.parse(response.body.to_s)
          raise Error, "#{where} returned JSON that is not an object" unless parsed.is_a?(Hash)

          parsed
        rescue JSON::ParserError
          # The parser's message quotes the body.
          raise Error.new("#{where} returned invalid JSON"), cause: nil
        end

        def where
          "Jev (POST #{@endpoint})"
        end
      end
    end
  end
end
