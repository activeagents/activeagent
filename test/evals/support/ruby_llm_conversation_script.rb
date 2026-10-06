# frozen_string_literal: true

# Drives a real RubyLLM tool-calling conversation — OpenAI's chat completions
# endpoint stubbed with WebMock — as plain `RubyLLM::Chat` messages and as
# `acts_as_chat` records on an in-memory SQLite database, and prints, as JSON,
# the Replay `ActiveAgent::Evals::RubyLLM.replay` builds from each.
#
# Runs out of process (see ruby_llm_conversation_test.rb) so the database, the
# RubyLLM configuration and the HTTP stubs stay out of the test suite's own.
#
#   ruby -Ilib test/evals/support/ruby_llm_conversation_script.rb [legacy]
#
# `legacy` (RubyLLM 2 only) replays the records alone, keeping the columns a
# RubyLLM 1.x `messages` table had (`tool_call_id`, `input_tokens`,
# `output_tokens`) with values that disagree with the conversation, the way a
# table reads between RubyLLM 2's upgrade migration and its cleanup; the
# replay must not read them. On RubyLLM 1.x those columns are the
# conversation, so the flag is ignored.
require "json"
require "active_record"
require "sqlite3"
require "webmock"
require "active_agent/evals/ruby_llm"

include WebMock::API
WebMock.enable!
WebMock.disable_net_connect!

V2 = Gem::Version.new(RubyLLM::VERSION) >= Gem::Version.new("2")
LEGACY = V2 && ARGV.include?("legacy")
output = { "ruby_llm" => RubyLLM::VERSION, "legacy" => LEGACY }

RubyLLM.configure do |config|
  config.openai_api_key = "sk-test"
  config.log_file = File::NULL if config.respond_to?(:log_file=)
  config.max_retries = 0 if config.respond_to?(:max_retries=)
  config.use_new_acts_as = true if config.respond_to?(:use_new_acts_as=)
end

class LookupOrder < RubyLLM::Tool
  description "Looks up an order"
  def execute = '{"status":"shipped"}'
end

# Returns an error Hash, RubyLLM's own convention for a failed tool.
class FailingHash < RubyLLM::Tool
  description "Reports a backend failure"
  def execute = { error: "backend timed out" }
end

# Returns the JSON an MCP tool failure arrives as.
class FailingJson < RubyLLM::Tool
  description "Reports an MCP failure"
  def execute = '{"error":"MCP tool failing_json timed out"}'
end

TOOLS = [ LookupOrder, FailingHash, FailingJson ].freeze

def tool_call(id, name) = { "id" => id, "type" => "function", "function" => { "name" => name, "arguments" => "{}" } }

def completion(message, prompt:, completion:, cached: 0)
  {
    status: 200, headers: { "Content-Type" => "application/json" },
    body: {
      id: "chatcmpl-1", object: "chat.completion", model: "gpt-4o-mini",
      choices: [ { index: 0, message: message, finish_reason: message["tool_calls"] ? "tool_calls" : "stop" } ],
      usage: { prompt_tokens: prompt, completion_tokens: completion, total_tokens: prompt + completion,
               prompt_tokens_details: { cached_tokens: cached } }
    }.to_json
  }
end

# The model calls lookup_order and failing_hash, then failing_json and a tool
# it was never given, then answers. Call ids are deliberately out of
# alphabetical order: the replay must keep the order they were made in.
RESPONSES = [
  completion({ "role" => "assistant", "content" => nil,
               "tool_calls" => [ tool_call("call_Zz1", "lookup_order"), tool_call("call_Mm1", "failing_hash") ] },
             prompt: 100, completion: 10, cached: 40),
  completion({ "role" => "assistant", "content" => nil,
               "tool_calls" => [ tool_call("call_Aa2", "failing_json"), tool_call("call_Bb2", "github__search_issues") ] },
             prompt: 200, completion: 20, cached: 150),
  completion({ "role" => "assistant", "content" => "Order ABC-123 shipped on Monday." }, prompt: 300, completion: 30)
].freeze

def stub_openai!
  WebMock.reset!
  stub = stub_request(:post, "https://api.openai.com/v1/chat/completions")
  RESPONSES.each_with_index { |response, index| stub = index.zero? ? stub.to_return(response) : stub.then.to_return(response) }
end

def replay_json(messages)
  ActiveAgent::Evals::RubyLLM.replay(messages, duration_ms: 5).to_h.transform_keys(&:to_s)
end

# Plain RubyLLM::Chat messages. The legacy run is about records only.
unless LEGACY
  stub_openai!
  options = { model: "gpt-4o-mini", provider: :openai, assume_model_exists: true }
  options[:protocol] = :chat_completions if V2
  chat = RubyLLM.chat(**options).with_tools(*TOOLS)
  chat.ask("Where is order ABC-123?")
  output["values"] = replay_json(chat.messages)
end

# acts_as_chat records, in the schema RubyLLM's install generator writes.
if !V2 && !RubyLLM.config.respond_to?(:use_new_acts_as=)
  output["records"] = { "skipped" => "acts_as_chat on ruby_llm #{RubyLLM::VERSION} is not covered" }
else
  ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
  ActiveRecord::Migration.verbose = false

  # RubyLLM's railtie requires these under Rails; a release that renames one
  # reads as a skip naming the file rather than a crash.
  internals = if V2
    %w[payload_helpers model tool_call usage batch chat_methods message_methods acts_as]
  else
    %w[payload_helpers chat_methods message_methods model_methods tool_call_methods acts_as]
  end
  begin
    internals.each { |file| require "ruby_llm/active_record/#{file}" }
  rescue LoadError => e
    output["records"] = { "skipped" => "ruby_llm #{RubyLLM::VERSION}: #{e.message}" }
    puts JSON.generate(output)
    exit
  end

  if V2

    ActiveRecord::Schema.define do
      create_table :ruby_llm_models do |t|
        t.string :model_id, null: false
        t.string :name, null: false
        t.string :provider, null: false
        t.string :family
        t.datetime :model_created_at
        t.integer :context_window
        t.integer :max_output_tokens
        t.date :knowledge_cutoff
        t.datetime :unlisted_at
        t.json :modalities, default: {}
        t.json :capabilities, default: []
        t.json :pricing, default: {}
        t.json :metadata, default: {}
        t.timestamps
      end
      create_table :chats do |t|
        t.references :ruby_llm_model, null: false
        t.boolean :cancelled, null: false, default: false
        t.timestamps
      end
      create_table :messages do |t|
        t.references :chat, null: false
        t.string :role, null: false
        t.text :content
        t.boolean :cache_until_here, null: false, default: false
        t.text :thinking_text
        t.text :thinking_signature
        t.json :citations
        t.json :server_tool_calls
        t.json :raw_content
        t.json :raw_reasoning
        t.string :finish_reason
        if LEGACY
          t.integer :tool_call_id
          t.integer :input_tokens
          t.integer :output_tokens
        end
        t.timestamps
      end
      create_table :ruby_llm_tool_calls do |t|
        t.references :message, polymorphic: true, null: false, index: false
        t.references :result, polymorphic: true, index: false
        t.string :tool_call_id, null: false
        t.string :name, null: false
        t.text :thought_signature
        t.string :approval
        t.boolean :remote, default: false, null: false
        t.json :arguments, default: {}
        t.timestamps
      end
      create_table :ruby_llm_usages do |t|
        t.references :chat, polymorphic: true, null: false, index: false
        t.references :message, polymorphic: true, index: false
        t.string :operation, null: false
        t.string :provider, null: false
        t.string :model, null: false
        t.string :status, null: false
        t.integer :input_tokens
        t.integer :output_tokens
        t.integer :cache_read_tokens
        t.integer :cache_write_tokens
        t.integer :thinking_tokens
        %i[input_cost output_cost cache_read_cost cache_write_cost thinking_cost total_cost].each do |column|
          t.decimal column, precision: 16, scale: 10
        end
        t.timestamps
      end
    end

    ActiveRecord::Base.include RubyLLM::ActiveRecord::ActsAs
    class Chat < ActiveRecord::Base
      acts_as_chat
    end

    class Message < ActiveRecord::Base
      acts_as_message
    end
  else
    ActiveRecord::Schema.define do
      create_table :models do |t|
        t.string :model_id, null: false
        t.string :name, null: false
        t.string :provider, null: false
        t.string :family
        t.datetime :model_created_at
        t.integer :context_window
        t.integer :max_output_tokens
        t.date :knowledge_cutoff
        t.json :modalities, default: {}
        t.json :capabilities, default: []
        t.json :pricing, default: {}
        t.json :metadata, default: {}
        t.timestamps
      end
      create_table :chats do |t|
        t.references :model
        t.timestamps
      end
      create_table :messages do |t|
        t.string :role, null: false
        t.text :content
        t.json :content_raw
        t.text :thinking_text
        t.text :thinking_signature
        t.integer :thinking_tokens
        t.integer :input_tokens
        t.integer :output_tokens
        t.integer :cached_tokens
        t.integer :cache_creation_tokens
        t.references :chat, null: false
        t.references :model
        t.references :tool_call
        t.timestamps
      end
      create_table :tool_calls do |t|
        t.string :tool_call_id, null: false
        t.string :name, null: false
        t.text :thought_signature
        t.json :arguments, default: {}
        t.references :message, null: false
        t.timestamps
      end
    end

    ActiveRecord::Base.include RubyLLM::ActiveRecord::ActsAs
    class Model < ActiveRecord::Base
      acts_as_model
    end

    class Chat < ActiveRecord::Base
      acts_as_chat
    end

    class Message < ActiveRecord::Base
      acts_as_message
    end

    class ToolCall < ActiveRecord::Base
      acts_as_tool_call
    end
  end

  stub_openai!
  record = Chat.new(model: "gpt-4o-mini")
  record.provider = "openai" if record.respond_to?(:provider=)
  record.assume_model_exists = true
  record.protocol = :chat_completions if V2
  record.save!
  record.with_tools(*TOOLS)
  record.ask("Where is order ABC-123?")

  if LEGACY
    record.messages.each_with_index do |message, index|
      message.update_columns(tool_call_id: 9_000 + index, input_tokens: 0, output_tokens: 0)
    end
  end

  output["records"] = replay_json(record.messages.order(:id))
end

puts JSON.generate(output)
