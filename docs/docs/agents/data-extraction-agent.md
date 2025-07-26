---
title: Data Extraction Agent
---
# {{ $frontmatter.title }}
Active Agent is designed to allow developers to create agents with ease. This guide will help you set up a Data Extraction Agent that can extract structured data from unstructured text, images, or PDFs.

## Creating the Data Extraction Agent
To create a Data Extraction Agent, you can use the `rails generate active_agent:agent data_extraction extract` command. This will create a new agent class in `app/agents/data_extraction_agent.rb` and a corresponding view template in `app/views/data_extraction_agent/extract.text.erb`.

```bash
rails generate active_agent:agent data_extraction extract
```

<<< @/../test/dummy/app/agents/data_extraction_agent.rb {ruby}
