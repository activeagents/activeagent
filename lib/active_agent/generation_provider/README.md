# ActiveAgent Generation Provider

This README provides information about the base generation provider class and the generation provider module interfaces in the ActiveAgent library.

## Base Generation Provider Class

The `ActiveAgent::GenerationProvider::Base` class serves as the foundation for all generation providers. It is located in `lib/active_agent/generation_provider/base.rb`.

### Key Features:

1. **Initialization**: The class is initialized with a configuration hash.
2. **Abstract Methods**: 
   - `generate(prompt)`: This method must be implemented by subclasses to handle the generation process.
   - `handle_response(response)`: This method must be implemented by subclasses to process the raw response.
3. **Protected Methods**:
   - `prompt_parameters`: Returns a hash with default parameters for the generation request.

### Usage:

Subclass `ActiveAgent::GenerationProvider::Base` to create specific providers for different AI services. Implement the required methods in your subclass.

## Generation Provider Module

The `ActiveAgent::GenerationProvider` module is defined in `lib/active_agent/generation_provider.rb`. It provides a flexible interface for configuring and using generation providers in ActiveAgent.

### Key Features:

1. **Configuration**: 
   - `configuration(provider_name, **options)`: Configures the provider using the given name and options.
   - `configure_provider(config)`: Creates a new instance of the specified provider.

2. **Provider Management**:
   - `generation_provider`: Getter for the current generation provider.
   - `generation_provider=`: Setter for the generation provider.
   - `generation_provider_name`: Getter for the name of the current provider.

3. **Default Provider**: OpenAI is set as the default provider if none is specified.

### Usage:

Include the `ActiveAgent::GenerationProvider` module in your classes to add generation provider functionality. Use the provided methods to configure and manage the generation provider for your class.

Example:

```ruby
class MyGenerator
  include ActiveAgent::GenerationProvider

  # Configure the provider
  configuration :openai, temperature: 0.8

  def generate_text(prompt)
    generation_provider.generate(prompt)
  end
end
