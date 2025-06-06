# ActiveAgent Documentation

Welcome to the ActiveAgent framework documentation.

## Overview

ActiveAgent is an AI framework for Rails that enables developers to build AI-powered applications with less code and more fun.

1. **Action Prompt**: The Prompt object is created with the necessary context, including messages, actions, and parameters.
2. **Generation Request**: The agent sends a request to the generation provider with the prompt context, including the messages and actions.
3. **Generation Response**: The generation provider processes the request and returns a response, which is then passed back to the agent.
4. **Response Handling**: The agent processes the response and generates a final output, which can be sent back to the user or used for further processing.
5. **Action Execution**: If the response includes actions, the agent executes them and updates the context accordingly.
6. **Context Update**: The context is updated with the new messages, actions, and parameters, and the cycle continues.
7. **Streaming**: If streaming is enabled, the agent can send partial responses to the user in real-time, enhancing the user experience.
8. **Callbacks**: After the generation process, callbacks can be triggered to perform additional actions, such as saving the context or sending notifications.
9. **Error Handling**: If any errors occur during the generation process, the agent can handle them gracefully and provide appropriate feedback to the user.
10. **Logging**: The entire process is logged for auditing and debugging purposes, allowing developers to track the flow of data and identify any issues that may arise.
11. **Testing**: The framework provides built-in testing tools to ensure that the prompt-generation process works as expected. Developers can write tests to verify the behavior of agents, actions, and generation providers, ensuring that the application is robust and reliable.
12. **Deployment**: The Active Agent framework is designed to be easily deployable in various environments, including cloud platforms and on-premises servers. Developers can use standard deployment tools and practices to ensure that their applications are scalable and maintainable.
13. **Monitoring**: The framework includes monitoring tools to track the performance of agents and generation providers. Developers can use these tools to identify bottlenecks and optimize the performance of their applications.
14. **Security**: The Active Agent framework includes security features to protect sensitive data and ensure that only authorized users can access the system. Developers can implement authentication and authorization mechanisms to secure their applications.
15. **Documentation**: The framework provides comprehensive documentation to help developers understand how to use the various features and components. This includes guides, API references, and examples to assist in the development process.
16. **Community**: The Active Agent framework has an active community of developers who contribute to its development and provide support. Developers can join forums, chat groups, and social media channels to connect with other users and share their experiences.
17. **Extensibility**: The framework is designed to be extensible, allowing developers to create custom actions, generation providers, and other components. This enables developers to tailor the framework to their specific needs and integrate it with existing systems.
18. **Best Practices**: The Active Agent framework encourages best practices in software development, including code organization, testing, and documentation. Developers are encouraged to follow these practices to ensure that their applications are maintainable and scalable.
19. **Support**: The framework provides support channels for developers to get help with any issues they may encounter. This includes forums, chat groups, and documentation to assist in troubleshooting and resolving problems.

## Quick Links

- [Getting Started](/docs/getting-started)
- [Framework Overview](/docs/framework)