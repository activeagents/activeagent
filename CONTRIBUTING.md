# Contributing to Active Agent

Thank you for your interest in contributing to Active Agent! This guide will help you get started with setting up your development environment and running tests.

## Getting Started

### Prerequisites

- Ruby 3.0 or higher
- Rails 7.0 or higher
- Git

### Environment Setup

1. **Fork and clone the repository**
   ```bash
   git clone https://github.com/your-username/activeagent.git
   cd activeagent
   ```

2. **Install dependencies**
   ```bash
   bundle install
   ```

3. **Set up environment variables**

   Copy the example environment file:
   ```bash
   cp .env.test.example .env.test
   ```

   Edit `.env.test` and add your API keys:
   ```bash
   OPENAI_ACCESS_TOKEN=your_openai_api_key_here
   OPEN_ROUTER_ACCESS_TOKEN=your_openrouter_api_key_here
   ANTHROPIC_ACCESS_TOKEN=your_anthropic_api_key_here
   ```

### Running Tests

To run the full test suite:

```bash
./bin/test
```

You can also run specific test files:

```bash
./bin/test test/agents/application_agent_test.rb
```

Or run tests with specific patterns:

```bash
./bin/test -n test_generation
```

### Code Quality

Before submitting your changes, make sure to run the linting tools:

```bash
./bin/rubocop
```

To auto-fix most style issues:

```bash
./bin/rubocop -a
```

## Making Changes

### Development Workflow

1. **Create a feature branch**
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make your changes**
   - Write tests for new functionality
   - Update documentation if needed
   - Follow the existing code style

3. **Test your changes**
   ```bash
   ./bin/test
   ./bin/rubocop
   ```

4. **Commit your changes**
   ```bash
   git add .
   git commit -m "Add descriptive commit message"
   ```

5. **Push to your fork**
   ```bash
   git push origin feature/your-feature-name
   ```

6. **Create a Pull Request**
   - Go to the original repository on GitHub
   - Click "New Pull Request"
   - Select your branch and provide a clear description

### Testing Guidelines

- Write tests for all new functionality
- Ensure existing tests continue to pass
- Use descriptive test names that explain what is being tested
- Use VCR to Mock external API calls

### Code Style

- Follow Ruby community standards
- Use descriptive variable and method names
- Add comments for complex logic
- Keep methods focused and single-purpose

## Types of Contributions

We welcome various types of contributions:

- **Bug fixes**: Help us identify and fix issues
- **Feature additions**: Add new functionality to the framework
- **Documentation**: Improve existing docs or add new examples
- **Tests**: Increase test coverage
- **Performance improvements**: Optimize existing code

## Getting Help

If you need help or have questions:

- Check the [documentation](https://docs.activeagents.ai)
- Open an issue on GitHub for bugs or feature requests
- Start a discussion for general questions

## API Key Setup

For testing different providers, you'll need API keys:

### OpenAI
1. Visit [OpenAI Platform](https://platform.openai.com/)
2. Create an account or sign in
3. Navigate to API Keys section
4. Create a new API key

### Anthropic
1. Visit [Anthropic Console](https://console.anthropic.com/)
2. Create an account or sign in
3. Navigate to API Keys section
4. Create a new API key

### OpenRouter
1. Visit [OpenRouter](https://openrouter.ai/)
2. Create an account or sign in
3. Navigate to Keys section
4. Create a new API key

## License

By contributing to Active Agent, you agree that your contributions will be licensed under the [MIT License](LICENSE).

Thank you for contributing to Active Agent! 🚀
