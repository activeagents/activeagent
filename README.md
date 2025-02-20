# Active Agent

## Install

### Gemfile
`gem 'activeagent'`

### CLI
`gem install activeagent`

## Agent

Create agents that take instructions, prompts, and perform actions

### Generation Provider

```ruby  
class SupportAgent < ActiveAgent::Base  
  generate_with :openai, model: ‘gpt-o3-mini’,  temperature: 0.7  
end  
```

`generate_with` sets the generation provider’s completion generation model and parameters.

`completion_response = SupportAgent.prompt(‘Help me!’).generate_now`

```ruby  
class SupportAgent < ActiveAgent::Base  
  generate_with :openai, model: ‘gpt-o3-mini’,  temperature: 0.7  
  embed_with :openai, model: ‘text-embedding-3-small’  
end  
```

`embed_with` sets the generation provider’s embedding generation model and parameters.

`embedding_response = SupportAgent.prompt(‘Help me!’).embed_now`

### Instructions

Instructions are system prompts that predefine the agent’s intention.

### Prompt

Action Prompt allows Active Agents to render plain text and HTML prompt templates. Calling generate on a prompt will send the prompt to the agent’s Generation Provider.

`SupportAgent.prompt(“What does CRUD and REST mean?”)`

### Queue Generation

Active Agent also supports queued generation with Active Job using a common Generation Job interface.

### Perform actions

Active Agents can define methods that are autoloaded as callable tools. These actions’ default schema will be provided to the agent’s context as part of the prompt request to the Generation Provider.

## Actions

```  
def get_cat_image_base64  
  uri = URI("https://cataas.com/cat")  
  response = Net::HTTP.get_response(uri)

  if response.is_a?(Net::HTTPSuccess)  
    image_data = response.body  
    Base64.strict_encode64(image_data)  
  else  
    raise "Failed to fetch cat image. Status code: #{response.code}"  
  end  
end

class SupportAgent < ActiveAgent  
  generate_with :openai,  
    model: "gpt-4o",  
    instructions: "Help people with their problems",  
    temperature: 0.7

   def get_cat_image  
    prompt { |format| format.text { render plain: get_cat_image_base64 } }  
  end  
end  
```

## Prompts

### Basic 

#### Plain text prompt and response templates

### HTML

### Action Schema JSON

response = SupportAgent.prompt(‘show me a picture of a cat’).generate_now

response.message
