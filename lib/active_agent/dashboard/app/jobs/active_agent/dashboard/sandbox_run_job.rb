# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    class SandboxRunJob < ApplicationJob
      queue_as :sandboxes

      PROVIDER_MODELS = {
        "anthropic" => "claude-haiku-4-5",
        "openai" => "gpt-4o",
        "ollama" => "llama3.1:8b"
      }.freeze

      # Execute a task in the sandbox using ActiveAgent's generate_later
      def perform(sandbox_session_id, run_id, task, provider = "anthropic")
        sandbox = SandboxSession.find(sandbox_session_id)
        return unless sandbox.can_run?

        started_at = Time.current

        # Broadcast that run has started
        broadcast_run_started(sandbox, run_id, task, provider)

        begin
          # Use ActiveAgent with generate_later for async processing
          # The agent's after_generation callback will handle recording results
          if defined?(ActiveAgent::Base)
            execute_with_active_agent(sandbox, run_id, task, provider, started_at)
          else
            # Fallback to direct API calls if ActiveAgent not available
            execute_with_fallback(sandbox, run_id, task, provider, started_at)
          end
        rescue => e
          Rails.logger.error("Sandbox run failed: #{e.message}")
          sandbox.update!(status: :ready, error_message: e.message)
          broadcast_run_error(sandbox, run_id, provider, e.message)
        end
      end

      private

      def execute_with_active_agent(sandbox, run_id, task, provider, started_at)
        # Use generate_now here since we're already in a background job
        # The ActiveAgent will handle the API call and callbacks
        response = SandboxDemoAgent.with(
          task: task,
          provider: provider,
          sandbox_session_id: sandbox.id,
          run_id: run_id,
          started_at: started_at
        ).ask.generate_now

        duration_ms = ((Time.current - started_at) * 1000).to_i

        # Extract result from response
        content = response&.message&.content || "No response generated"
        input_tokens = response&.usage&.[](:input_tokens) || 0
        output_tokens = response&.usage&.[](:output_tokens) || 0
        tokens = input_tokens + output_tokens

        # Record the run
        run = sandbox.record_run!(
          task: task,
          result: content,
          duration_ms: duration_ms,
          tokens: tokens,
          screenshots: [],
          provider: provider
        )

        sandbox.update!(status: :ready)
        broadcast_run_complete(sandbox, run_id, run)

      rescue => e
        Rails.logger.error("ActiveAgent execution failed: #{e.message}")
        # Fallback to direct API
        execute_with_fallback(sandbox, run_id, task, provider, started_at)
      end

      def execute_with_fallback(sandbox, run_id, task, provider, started_at)
        result = case provider
        when "anthropic"
          execute_with_anthropic(task)
        when "openai"
          execute_with_openai(task)
        when "ollama"
          execute_with_ollama(task)
        else
          { content: "Error: Unknown provider '#{provider}'", tokens: 0, screenshots: [] }
        end

        duration_ms = ((Time.current - started_at) * 1000).to_i

        # Record the run
        run = sandbox.record_run!(
          task: task,
          result: result[:content],
          duration_ms: duration_ms,
          tokens: result[:tokens] || 0,
          screenshots: result[:screenshots] || [],
          provider: provider
        )

        sandbox.update!(status: :ready)
        broadcast_run_complete(sandbox, run_id, run)
      end

      def execute_with_anthropic(task)
        api_key = Rails.application.credentials.dig(:anthropic, :api_key) || ENV["ANTHROPIC_API_KEY"]

        unless api_key.present?
          Rails.logger.warn("Anthropic API key not configured")
          return { content: "Error: Anthropic API key is not configured — set ANTHROPIC_API_KEY or add it to credentials", tokens: 0, screenshots: [] }
        end

        require "net/http"
        require "json"

        uri = URI("https://api.anthropic.com/v1/messages")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.read_timeout = 60

        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request["x-api-key"] = api_key
        request["anthropic-version"] = "2023-06-01"

        request.body = {
          model: PROVIDER_MODELS["anthropic"],
          max_tokens: 1024,
          system: default_system_prompt,
          messages: [ { role: "user", content: task } ]
        }.to_json

        response = http.request(request)
        result = JSON.parse(response.body)

        if result["error"]
          raise "Anthropic API error: #{result['error']['message']}"
        end

        content = result.dig("content", 0, "text") || "No response generated"
        input_tokens = result.dig("usage", "input_tokens") || 0
        output_tokens = result.dig("usage", "output_tokens") || 0

        { content: content, tokens: input_tokens + output_tokens, screenshots: [] }
      rescue => e
        Rails.logger.error("Anthropic API call failed: #{e.message}")
        { content: "Error: #{e.message}", tokens: 0, screenshots: [] }
      end

      def execute_with_openai(task)
        api_key = Rails.application.credentials.dig(:openai, :api_key) || ENV["OPENAI_API_KEY"]

        unless api_key.present?
          Rails.logger.warn("OpenAI API key not configured")
          return { content: "Error: OpenAI API key is not configured — set OPENAI_API_KEY or add it to credentials", tokens: 0, screenshots: [] }
        end

        require "net/http"
        require "json"

        uri = URI("https://api.openai.com/v1/chat/completions")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.read_timeout = 60

        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request["Authorization"] = "Bearer #{api_key}"

        request.body = {
          model: PROVIDER_MODELS["openai"],
          max_tokens: 1024,
          messages: [
            { role: "system", content: default_system_prompt },
            { role: "user", content: task }
          ]
        }.to_json

        response = http.request(request)
        result = JSON.parse(response.body)

        if result["error"]
          raise "OpenAI API error: #{result['error']['message']}"
        end

        content = result.dig("choices", 0, "message", "content") || "No response generated"
        prompt_tokens = result.dig("usage", "prompt_tokens") || 0
        completion_tokens = result.dig("usage", "completion_tokens") || 0

        { content: content, tokens: prompt_tokens + completion_tokens, screenshots: [] }
      rescue => e
        Rails.logger.error("OpenAI API call failed: #{e.message}")
        { content: "Error: #{e.message}", tokens: 0, screenshots: [] }
      end

      def execute_with_ollama(task)
        ollama_url = Rails.application.credentials.dig(:ollama, :url) || ENV["OLLAMA_URL"] || "http://localhost:11434"

        require "net/http"
        require "json"

        uri = URI("#{ollama_url}/api/generate")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.read_timeout = 120 # Ollama can be slower

        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"

        request.body = {
          model: PROVIDER_MODELS["ollama"],
          prompt: "#{default_system_prompt}\n\nUser: #{task}\n\nAssistant:",
          stream: false
        }.to_json

        response = http.request(request)
        result = JSON.parse(response.body)

        if result["error"]
          raise "Ollama API error: #{result['error']}"
        end

        content = result["response"] || "No response generated"
        # Ollama doesn't provide token counts in the same way
        tokens = (result["prompt_eval_count"] || 0) + (result["eval_count"] || 0)

        { content: content, tokens: tokens, screenshots: [] }
      rescue => e
        Rails.logger.error("Ollama API call failed: #{e.message}")
        { content: "Error: #{e.message}\n\nMake sure Ollama is running locally with: ollama serve", tokens: 0, screenshots: [] }
      end

      def default_system_prompt
        <<~PROMPT
          You are a helpful AI assistant. Answer the user's question or complete their task concisely and accurately.

          If the task involves browser automation, describe what actions you would take step by step.
        PROMPT
      end

      def broadcast_run_started(sandbox, run_id, task, provider)
        ActionCable.server.broadcast(
          "sandbox_#{sandbox.session_id}",
          {
            type: "run_started",
            run_id: run_id,
            provider: provider,
            task: task,
            started_at: Time.current.iso8601
          }
        )
        Rails.logger.info "[SandboxRunJob] Broadcast run_started for #{provider} (#{run_id})"
      end

      def broadcast_run_complete(sandbox, run_id, run)
        ActionCable.server.broadcast(
          "sandbox_#{sandbox.session_id}",
          {
            type: "run_complete",
            run_id: run_id,
            provider: run[:provider],
            run: run,
            sandbox: sandbox.summary
          }
        )
        Rails.logger.info "[SandboxRunJob] Broadcast run_complete for #{run[:provider]} (#{run_id})"
      end

      def broadcast_run_error(sandbox, run_id, provider, error)
        ActionCable.server.broadcast(
          "sandbox_#{sandbox.session_id}",
          {
            type: "run_error",
            run_id: run_id,
            provider: provider,
            error: error,
            sandbox: sandbox.summary
          }
        )
        Rails.logger.info "[SandboxRunJob] Broadcast run_error for #{provider} (#{run_id})"
      end
    end
  end
end
