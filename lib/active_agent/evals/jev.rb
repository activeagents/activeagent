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
    # A Judge whose bounded decisions are answered by a "System One" model:
    # Jev, TypeSafe AI's hosted one, or OpenJevX, the open re-implementation
    # of its protocol that runs on a laptop CPU. Such a model generates no
    # text: a request carries a `state` (the text to judge) and named
    # questions — a Score over described levels, a Choice over options, a
    # yes/no — and the answer is one structured decision per question with a
    # calibrated probability behind it, billed (when hosted) on input tokens
    # only.
    #
    # Of the three calls a Judge serves, two end in such a decision and become
    # questions: `:score` is one Score question over the gem's own scoring
    # prompt, and `:verdict`'s winner is one Choice over the compared model
    # labels, each described by its results. The language tasks — the
    # verdict's rationale and the whole of `:recommend` — go to `text_judge`,
    # an ordinary Judge, when one is given; without one the rationale is a
    # sentence naming the probability and a recommendation is nil, which the
    # runner treats as "no recommendation" rather than a failure. That is the
    # hybrid pattern the DeepEval and Langfuse integrations settled on: the
    # language model explains, the decision model decides.
    #
    #   require "active_agent/evals/jev"
    #
    #   # Hosted Jev, the key from TYPESAFE_API_KEY:
    #   judge = ActiveAgent::Evals::Jev.judge(
    #     label: "jev-latest",
    #     text_judge: ActiveAgent::Evals::Judge.new(label: "claude-haiku-4-5") { |instructions:, prompt:| ... }
    #   )
    #
    #   # OpenJevX on this machine (`docker compose up` in its repository), no key:
    #   judge = ActiveAgent::Evals::Jev.judge(label: "openjevx", base_url: ActiveAgent::Evals::Jev::OPENJEVX_BASE_URL)
    #
    #   ActiveAgent::Evals::Runner.new(scenarios:, models:, replay:, judge: judge).call
    #
    # The wire format is Client's alone: read its doc comment before touching
    # a field name.
    module Jev
      DEFAULT_BASE_URL = "https://api.typesafe.ai"
      DEFAULT_MODEL = "jev-latest"
      API_KEY_ENV = "TYPESAFE_API_KEY"
      # Where OpenJevX's container serves the protocol (https://github.com/muthuishere/openjevx):
      # `docker compose up -d --build` there, then this base URL and no key.
      OPENJEVX_BASE_URL = "http://127.0.0.1:21118"

      # The one question each kind asks. The criterion or task, the user's
      # message and the answer are all in the state, the gem's own prompt.
      SCORE_QUESTION = "How well does the assistant's answer satisfy the criterion or task set out in the state?"
      # A Score question's levels, each described. The model answers the
      # expected level, which Client normalises to 0.0..1.0 by the last index;
      # five levels keep the grade's meaning and give the expectation room to
      # fall between them.
      SCORE_LEVELS = [
        "fails completely: a refusal, a guess, or an unrelated answer",
        "mostly fails: touches the task but gets the substance wrong or leaves most of it undone",
        "partly satisfies: right in part, with gaps or errors a user would notice",
        "mostly satisfies: does the task with minor omissions",
        "fully satisfies: specific, correct and complete, with a clear next step for the user"
      ].freeze
      VERDICT_QUESTION = "Which model best accomplishes the agent's goals, weighing task completion first " \
                         "and cost and latency second?"

      # Judge#verdict lists one line per compared model under this heading,
      # each opening with the model's label and going on to its results; the
      # labels are the Choice's options and the results their descriptions.
      RESULTS_HEADING = "Results per model:"
      RESULT_LINE = /\A(.+?): (pass rate .*)\z/
      # The line the gem's prompts end with for a language model, which a
      # decision model has no use for in its state.
      LANGUAGE_MODEL_LINE = /\ARespond (?:ONLY|only) with JSON/

      # Raised by Client for anything that is not a usable answer: the endpoint
      # unreachable, a rejection, a body that is not JSON. Judge#ask turns it
      # into a nil answer and a warning, so a run degrades to rule scoring.
      class Error < StandardError; end

      # One decision: its value (a 0..1 score, or the chosen option), the
      # model's calibrated probability and confidence for it, what the call
      # cost in input tokens when the server says, the model that answered,
      # and the decision as the server sent it.
      Answer = Struct.new(:value, :probability, :confidence, :input_tokens, :model, :decision, keyword_init: true)

      class << self
        # Builds a Judge that sends its bounded decisions to a System One model.
        #
        # @param label [String] how reports name the judge
        # @param api_key [String, nil] defaults to `TYPESAFE_API_KEY`; required
        #   for the hosted endpoint, not for a server of your own
        # @param model [String, nil] `jev-latest`, `jev-1.13` or `jev-preview`;
        #   the hosted endpoint defaults to `jev-latest`, a server of your own
        #   is sent none unless given one
        # @param base_url [String] where `/v1/systemone` is posted: TypeSafe's
        #   endpoint by default, OPENJEVX_BASE_URL for a local OpenJevX
        # @param text_judge [Judge, nil] answers `:recommend` and writes the verdict's rationale
        # @param on_usage [#call, nil] called after each answered call with
        #   `{ "kind", "model", "input_tokens", "output_tokens", "cost" }`; output
        #   tokens are always 0 and the cost nil, since nothing is generated and
        #   the price per input token is not yet known; input tokens are nil
        #   when the server reports none (OpenJevX does not). An error it raises
        #   is logged, not propagated, so bookkeeping never costs a grade
        # @return [Judge]
        # @raise [ArgumentError] for the hosted endpoint without a key
        def judge(label:, api_key: nil, model: nil, base_url: DEFAULT_BASE_URL, text_judge: nil, on_usage: nil)
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
          answer = client.score(state_for(prompt), SCORE_QUESTION, SCORE_LEVELS)
          report_usage(on_usage, :score, answer)
          JSON.generate("score" => answer.value)
        end

        def verdict(client, text_judge, instructions, prompt, on_usage)
          candidates = compared_models(prompt)
          return nil if candidates.empty?

          answer = client.choose(state_for(prompt), VERDICT_QUESTION, candidates)
          report_usage(on_usage, :verdict, answer)
          winner = answer.value.to_s
          # Judge#verdict discards an unknown winner itself; stopping here
          # spares the text judge a rationale nobody will read.
          return nil unless candidates.key?(winner)

          JSON.generate("winner" => winner, "rationale" => rationale(text_judge, instructions, prompt, answer))
        end

        # `{ label => its results }` from the lines under the results heading,
        # up to the blank line that ends them, in the order the prompt lists them.
        def compared_models(prompt)
          section = prompt.to_s.split(RESULTS_HEADING, 2)[1].to_s.split(/\n[ \t]*\n/, 2)[0].to_s
          section.lines.each_with_object({}) do |line, models|
            label, results = line.strip.match(RESULT_LINE)&.captures
            models[label.strip] = results.strip if label.present?
          end
        end

        # The gem's prompt as the state, without its closing request for JSON.
        def state_for(prompt)
          prompt.to_s.lines.reject { |line| line.match?(LANGUAGE_MODEL_LINE) }.join.strip
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

      # The wire format, in one place: the System One protocol as OpenJevX
      # documents and serves it (https://huggingface.co/muthuishere/openjevx,
      # whose request and answer shapes it states match TypeSafe's
      # `POST /v1/systemone`). TypeSafe's own reference was not reachable when
      # this was written, so against the hosted endpoint this is the best
      # evidence rather than a confirmation; nothing outside this class reads
      # a field of a request or a response, so a difference is a fix here.
      #
      # Request, `POST {base_url}/v1/systemone`, with `Authorization: Bearer <key>`
      # when there is a key and `model` when one is named:
      #
      #   { "model": "jev-latest",
      #     "state": "<the text to judge>",
      #     "questions": {
      #       "score":  { "type": "score",  "instructions": "How well ...?",
      #                   "criteria": ["fails completely: ...", "...", "fully satisfies: ..."] },
      #       "winner": { "type": "choice", "instructions": "Which model ...?",
      #                   "criteria": { "gpt-5-mini": "pass rate 90.0%, ...", "qwen3:8b": "pass rate 60.0%, ..." } } } }
      #
      # A `score`'s criteria are its levels in order, a `choice`'s its options
      # (a list of names, or names with descriptions), and a `noul` is a
      # yes/no. Response, one answer per question under its name:
      #
      #   { "answers": {
      #       "score":  { "type": "score",  "score": 3.2, "probabilities": { "0": 0.02, ..., "4": 0.45 }, "confidence": 0.45 },
      #       "winner": { "type": "choice", "choice": "qwen3:8b", "probabilities": { "gpt-5-mini": 0.19, "qwen3:8b": 0.81 }, "confidence": 0.81 } } }
      #
      # A score is the expected level, which `score` normalises to 0.0..1.0
      # by the last level's index. OpenJevX reports no usage; a hosted answer
      # may, under `usage`, and may name the `model` that answered. Reading is
      # tolerant on purpose — the answer under `answers`, `results` or the top
      # level, as an object or a bare value; the decision under its own name
      # or `value`, `answer` or `decision`; the probability from the chosen
      # option's entry in `probabilities`, or `probability`, or the confidence
      # — so a renamed field is read rather than raised on. That tolerance
      # stays in here.
      class Client
        PATH = "/v1/systemone"
        ANSWER_SECTIONS = %w[answers results].freeze
        SCORE_KEYS = %w[score value answer decision].freeze
        CHOICE_KEYS = %w[choice value answer decision].freeze
        PROBABILITY_KEYS = %w[probability calibrated_probability].freeze
        CONFIDENCE_KEYS = %w[confidence answer_confidence].freeze
        INPUT_TOKEN_KEYS = %w[input_tokens prompt_tokens tokens].freeze

        attr_reader :model, :endpoint

        # @param api_key [String, nil] required for the hosted endpoint
        # @param model [String, nil] sent when named; the hosted endpoint defaults to DEFAULT_MODEL
        # @param base_url [String]
        def initialize(api_key:, model: nil, base_url: DEFAULT_BASE_URL, open_timeout: 10, timeout: 60)
          base = base_url.to_s.chomp("/")
          hosted = base == DEFAULT_BASE_URL
          if api_key.blank? && hosted
            raise ArgumentError, "Jev.judge needs an api_key:, or #{API_KEY_ENV} in the environment, for #{DEFAULT_BASE_URL}"
          end

          @api_key = api_key.presence
          @model = model.presence&.to_s || (DEFAULT_MODEL if hosted)
          @endpoint = URI.parse("#{base}#{PATH}")
          @open_timeout = open_timeout
          @timeout = timeout
        end

        # One Score question over `state`, its answer the expected level over
        # `levels` normalised to 0.0..1.0.
        #
        # @param levels [Array<String>] the levels in order, each described
        # @return [Answer]
        def score(state, question, levels)
          answer = ask(state, "score", "type" => "score", "instructions" => question, "criteria" => levels)
          level = number(first(answer.decision, SCORE_KEYS))
          raise Error, "#{where} answered the score question without a number" if level.nil?

          answer.value = (level / (levels.size - 1).to_f).clamp(0.0, 1.0)
          answer.probability ||= answer.confidence
          answer
        end

        # One Choice question over `state`; the answer's value is the chosen
        # option as sent.
        #
        # @param options [Array<String>, Hash{String => String}] the options,
        #   or the options with a description of each
        # @return [Answer]
        def choose(state, question, options)
          criteria = options.is_a?(Hash) ? options.transform_values(&:to_s) : Array(options).map(&:to_s)
          answer = ask(state, "winner", "type" => "choice", "instructions" => question, "criteria" => criteria)
          answer.value = first(answer.decision, CHOICE_KEYS)&.to_s
          probabilities = answer.decision["probabilities"]
          answer.probability ||= number(probabilities[answer.value]) if probabilities.is_a?(Hash) && answer.value
          answer.probability ||= answer.confidence
          answer
        end

        private

        def ask(state, name, question)
          request = { "state" => state, "questions" => { name => question } }
          request = { "model" => @model }.merge(request) if @model
          body = parse(post(JSON.generate(request)))
          decision = answer_for(body, name)
          raise Error, "#{where} answered without a decision for #{name}" if decision.nil?

          decision = { "value" => decision } unless decision.is_a?(Hash)
          reported = body["model"]
          Answer.new(
            probability: number(first(decision, PROBABILITY_KEYS)),
            confidence: number(first(decision, CONFIDENCE_KEYS)),
            input_tokens: input_tokens(body),
            model: reported.is_a?(String) && reported.present? ? reported : @model,
            decision: decision
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
          request["Authorization"] = "Bearer #{@api_key}" if @api_key
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
          raise Error, "#{where} rejected the request (HTTP #{status}); check the API key (#{API_KEY_ENV})" if [ 401, 403 ].include?(status)
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
