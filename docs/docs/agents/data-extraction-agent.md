---
title: Data Extraction Agent
---
# {{ $frontmatter.title }}
Active Agent is designed to allow developers to create agents with ease. This guide will help you set up a Data Extraction Agent that can extract structured data from unstructured text, images, or PDFs.

## Creating the Data Extraction Agent
To create a Data Extraction Agent, you can use the `rails generate active_agent:agent data_extraction parse_content` command. This will create a new agent class in `app/agents/data_extraction_agent.rb` and a corresponding view template in `app/views/data_extraction_agent/extract.text.erb`.

```bash
rails generate active_agent:agent data_extraction parse_content
```

::: code-group

<<< @/../test/dummy/app/agents/data_extraction_agent.rb {ruby}

<<< @/../test/dummy/app/views/data_extraction_agent/chart_schema.json.erb {json}

<<< @/../test/dummy/app/views/data_extraction_agent/resume_schema.json.erb {json}

:::

## Structured output
The Data Extraction Agent is designed to extract structured data from unstructured text, images, or PDFs. It uses a schema to define the structure of the output data. The schema is defined in a JSON file located in `app/views/data_extraction_agent/`. The agent will use this schema to instruct the generation provider to extract the data in the specified format.

<<< @/../test/agents/data_extraction_agent_test.rb#data_extraction_agent_parse_chart_with_structured_output {ruby:line-numbers}

::: details Example prompt output
```ruby
irb(#<DataExtractionAgentTest:0x0...):005> prompt
=> 
#<ActiveAgent::ActionPrompt::Prompt:0x000000016bffb2e0
 @action_choice="",
 @actions=[],
 @agent_class=ApplicationAgent,
 @body="",
 @charset="UTF-8",
 @content_type="multipart/mixed",
 @context=[],
 @context_id=nil,
 @headers={},
 @instructions="You are a helpful assistant.",
 @message=
  <ActiveAgent::ActionPrompt::Message:0xa8c0 @action_id=nil, @action_name=nil, @action_requested=false, @charset="UTF-8", @content=[<ActiveAgent::ActionPrompt::Message:0xa8d4 @action_id=nil, @action_name=nil, @action_requested=false, @charset="UTF-8", @content="data:image/jpeg;base64,...", @role=:user>, <ActiveAgent::ActionPrompt::Message:0xa8e8 @action_id=nil, @action_name=nil, @action_requested=false, @charset="UTF-8", @content="Parse the content of the file or image", @role=:user>], @role=:user>,
 @messages=
  [<ActiveAgent::ActionPrompt::Message:0xa8fc @action_id=nil, @action_name=nil, @action_requested=false, @charset="UTF-8", @content="You are a helpful assistant.", @role=:system>,
   <ActiveAgent::ActionPrompt::Message:0xa8c0 @action_id=nil, @action_name=nil, @action_requested=false, @charset="UTF-8", @content=[<ActiveAgent::ActionPrompt::Message:0xa8d4 @action_id=nil, @action_name=nil, @action_requested=false, @charset="UTF-8", @content="data:image/jpeg;base64,...", @role=:user>, <ActiveAgent::ActionPrompt::Message:0xa8e8 @action_id=nil, @action_name=nil, @action_requested=false, @charset="UTF-8", @content="Parse the content of the file or image", @role=:user>], @role=:user>],
 @mime_version="1.0",
 @multimodal=true,
 @options=
  {:model=>"gpt-4o-mini",
   :instructions=>"You are a helpful assistant.",
   "service"=>"OpenAI",
   "api_key"=>"sk-...",
   "model"=>"gpt-4o-mini",
   "temperature"=>0.7},
tent of the file or image", @role=:user>], @role=:user>],
 @mime_version="1.0",
 @multimodal=true,
 @options=
  {:model=>"gpt-4o-mini",
   :instructions=>"You are a helpful assistant.",
   "service"=>"OpenAI",
   "api_key"=>"sk-...",
   "model"=>"gpt-4o-mini",
   "temperature"=>0.7},
 @output_schema=
  {"format"=>
    {"type"=>"json_schema",
     "name"=>"chart_schema",
     "schema"=>
      {"type"=>"object",
       "properties"=>
        {"title"=>{"type"=>"string", "description"=>"The title of the chart."},
         "data_points"=>{"type"=>"array", "items"=>{"$ref"=>"#/$defs/data_point"}}},
       "required"=>["title", "data_points"],
       "additionalProperties"=>false,
       "$defs"=>
        {"data_point"=>
          {"type"=>"object",
           "properties"=>
            {"label"=>
              {"type"=>"string", "description"=>"The label for the data point."},
             "value"=>
              {"type"=>"number", "description"=>"The value of the data point."}},
           "required"=>["label", "value"],
           "additionalProperties"=>false}}}}},
 @params=
  {:output_schema=>:chart_schema,
   :image_path=>
    #<Pathname:/Users/justinbowen/Documents/GitHub/activeagents/lib/activeagent/test/f
ixtures/images/sales_chart.png>},
 @parts=
  [#<ActiveAgent::ActionPrompt::Message:0xa8c0 @action_id=nil, @action_name=nil, @acti
on_requested=false, @charset="UTF-8", @content=[#<ActiveAgent::ActionPrompt::Message:0
xa8d4 @action_id=nil, @action_name=nil, @action_requested=false, @charset="UTF-8", @co
ntent="data:image/jpeg;base64,iVBORw0KGgoAAAANSUhEUgAAAZAAAAEsEAYAAAC9JzmBAAAAIGNIUk0A
AHom\nAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAAGYktHRP//////\n/wlY99wAAEyvSURBVH
ja7d13XE3/4wfwV5qSzIzILMoeRQMhMzITyZYie0RW\ntsomJXzsGdlpoDIaRiW7bIlQWigN9fuD+z1++vQhdK
4+n9fzn/...", @role=:user>, #<ActiveAgent::ActionPrompt::Message:0xa8e8 @action_id=nil
, @action_name=nil, @action_requested=false, @charset="UTF-8", @content="Parse the con
tent of the file or image", @role=:user>], @role=:user>]>
```
:::

In the example above, we have two schemas: `chart_schema.json.erb` and `resume_schema.json.erb`. These schemas define the structure of the data that the agent will extract and can be passed into the agent's `parse_content` action using the `output_schema` parameter. This provides a flexible interface for the agent to extract data in various structured formats.

