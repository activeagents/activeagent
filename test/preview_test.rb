require "test_helper"
require "tmpdir"

class AgentPreviewTest < ActiveSupport::TestCase
  class SyntheticAgent < ActiveAgent::Base
    generate_with :mock

    def greet
      prompt(message: "Synthetic preview")
    end
  end

  class SyntheticPreview < ActiveAgent::Preview
    def greet
      SyntheticAgent.greet
    end
  end

  test "the default preview interceptor accepts a generation" do
    generation = SyntheticPreview.call(:greet)
    assert_kind_of ActiveAgent::Generation, generation
    assert_includes generation.prompt_preview, "Synthetic preview"
  end

  test "mail-shaped previews still have inline images rewritten" do
    part = Struct.new(:body) do
      def decoded = body
    end.new('<img src="cid:synthetic">')
    attachment = Struct.new(:body) do
      def attachment? = true
      def cid = "synthetic"
      def mime_type = "image/png"
    end.new(Struct.new(:raw_source).new("synthetic-image"))
    context = Struct.new(:html_part, :all_parts).new(part, [ attachment ])

    ActiveAgent::InlinePreviewInterceptor.previewing_prompt(context)
    assert_includes part.body, "data:image/png;base64,c3ludGhldGljLWltYWdl"
  end

  test "previews added after the first discovery are discovered" do
    original = ActiveAgent::Base.preview_paths
    Dir.mktmpdir do |directory|
      ActiveAgent::Base.preview_paths = [ directory ]
      ActiveAgent::Preview.all
      File.write(File.join(directory, "late_preview.rb"), "class LatePreview < ActiveAgent::Preview; end")
      assert_includes ActiveAgent::Preview.all.map(&:name), "LatePreview"
    end
  ensure
    ActiveAgent::Base.preview_paths = original
    Object.send(:remove_const, :LatePreview) if Object.const_defined?(:LatePreview)
  end
end
