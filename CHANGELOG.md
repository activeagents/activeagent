# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.2] - 2025-04-15

### Added
- CI configuration for stable GitHub releases moving forward.
- Test coverage for core features: ActionPrompt rendering, tool calls, and embeddings.
- Enhance streaming to support tool calls during stream. Previously, streaming mode blocked tool call execution.
- Fix layout rendering bug when no block is passed and views now render correctly without requiring a block.

### Removed 
- Generation Provider module and Action Prompt READMEs have been removed, but will be updated along with the main README in the next release.