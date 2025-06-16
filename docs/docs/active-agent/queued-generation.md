# Queued Generation

## Generate later
Queued generation allows you to handle prompt generation asynchronously, which is particularly useful for long-running tasks or when you want to improve the responsiveness of your application.

Generation can be performed using Active Job to handle the prompt-generation and perform actions asynchronously. This is the most common way to handle generation in production applications, as it allows for better scalability and responsiveness.

To perform queued generation, you can use the `generate_later` method, which enqueues the generation job to be processed later by Active Job. 

```ruby
ApplicationAgent.with(message: params[:message], messages: params[:messages]).text_prompt.generate_later
```

