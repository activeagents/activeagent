# Queued Generation

## Generate Later

Queued generation allows you to handle prompt generation asynchronously, which is particularly useful for long-running tasks or when you want to improve the responsiveness of your application.

Generation can be performed using Active Job to handle the prompt-generation and perform actions asynchronously. This is the most common way to handle generation in production applications, as it allows for better scalability and responsiveness.

To perform queued generation, you can use the `generate_later` method, which enqueues the generation job to be processed later by Active Job.

### Basic Usage

```ruby
# Enqueue a generation job
generation = SupportAgent.with(message: "Hello!").ask
generation.generate_later

# The job is processed asynchronously by Active Job
```

### Testing Generate Later

<<< @/../test/agents/prompt_interface_test.rb#122-140{ruby:line-numbers}

## Custom Queue Configuration

You can specify custom queue names and priorities:

```ruby
# Use a specific queue
generation = DataExtractionAgent.with(
  image_path: "path/to/image.png"
).parse_content

generation.generate_later(queue: :high_priority)

# With priority
generation.generate_later(queue: :agents, priority: :high)

# Delayed execution
generation.generate_later(wait: 10.minutes)

# Wait until specific time
generation.generate_later(wait_until: 1.hour.from_now)
```

### Custom Queue Example

<<< @/../test/agents/prompt_interface_test.rb#144-160{ruby:line-numbers}

