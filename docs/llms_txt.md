---
title: LLMs.txt
description: Machine-readable documentation index for AI tools and large language models following the llms.txt specification.
---
# {{ $frontmatter.title }}

Active Agent publishes an [`llms.txt`](/llms.txt) file — a machine-readable index of all documentation pages, following the [llms.txt specification](https://llmstxt.org).

## What is llms.txt?

The llms.txt spec provides a standard way for websites to offer documentation in a format optimized for large language models. Instead of crawling HTML pages, AI tools can fetch a single markdown file with structured links and descriptions for every page.

## Using llms.txt

Point your AI tool at the file:

```
https://docs.activeagents.ai/llms.txt
```

Most AI-powered coding assistants and chat interfaces can ingest this URL directly to get full context on Active Agent.

## Regenerating

The file is regenerated on every docs deploy as part of the VitePress build. To regenerate locally:

```bash
npm run docs:build
```

This parses frontmatter from all documentation markdown files and writes `llms.txt` to the build output directory.
