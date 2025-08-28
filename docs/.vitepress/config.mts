import { defineConfig } from 'vitepress'
import { tabsMarkdownPlugin } from 'vitepress-plugin-tabs'

import {
  groupIconMdPlugin,
  groupIconVitePlugin,
  localIconLoader,
} from "vitepress-plugin-group-icons"

// https://vitepress.dev/reference/site-config
export default defineConfig({
  markdown: {
    config(md) {
      md.use(groupIconMdPlugin),
      md.use(tabsMarkdownPlugin)
    }
  },
  vite: {
    plugins: [
      groupIconVitePlugin({
        customIcon: {
          ruby: "vscode-icons:file-type-ruby",
          ".rb": "vscode-icons:file-type-ruby",
          ".erb": "vscode-icons:file-type-erb",
          ".html.erb": "https://raw.githubusercontent.com/marcoroth/herb/refs/heads/main/docs/.vitepress/assets/herb.svg",
          openai: 'logos:openai-icon',
          anthropic: 'logos:anthropic-icon',
          google: 'logos:google-icon',
          ollama: 'simple-icons:ollama',
          openrouter: localIconLoader(import.meta.url, './assets/icons/openrouter.svg'),
        }
      }),
    ],
  },
  title: "Active Agent",
  description: "The AI framework for Rails with less code & more fun.",
  head: [
    ['link', { rel: 'icon', href: '/activeagent.png' }],
    ['link', { rel: 'icon', href: '/favicon-16x16.png', sizes: '16x16' }],
    ['link', { rel: 'icon', href: '/favicon-32x32.png', sizes: '32x32' }],
    ['link', { rel: 'apple-touch-icon', href: '/apple-touch-icon.png' }],
    ['meta', { property: 'og:image', content: '/social.png' }],
    ['meta', { property: 'og:title', content: 'Active Agent' }],
    ['meta', { property: 'og:description', content: 'The AI framework for Rails with less code & more fun.' }],
    ['meta', { property: 'og:url', content: 'https://activeagents.ai' }],
    ['meta', { property: 'og:type', content: 'website' }],
    ['script', { async: '', defer: '', src: 'https://buttons.github.io/buttons.js' }]
  ],
  cleanUrls: true,
  themeConfig: {
    search: {
      provider: 'local',
    },
    editLink: {
      pattern: 'https://github.com/activeagents/activeagent/edit/main/docs/:path',
      text: 'Suggest changes to this page on GitHub'
    },
    // https://vitepress.dev/reference/default-theme-config
    nav: [
      { text: 'Home', link: '/' },
      { text: 'Docs', link: '/docs' },
      { text: 'GitHub', link: 'https://github.com/activeagents/activeagent' }
    ],
    sidebar: [
      {
        text: 'Overview',
        link: '/docs',
      },
      {
        text: 'Getting Started',
        link: '/docs/getting-started',
      },
      {
        text: 'Framework',
        items: [
          // { text: 'Rails Integration', link: '/docs/framework/rails-integration' },
          { text: 'Active Agent', link: '/docs/framework/active-agent' },
          { text: 'Action Prompt', link: '/docs/framework/action-prompt' },
          { text: 'Generation Provider', link: '/docs/framework/generation-provider' },
          { text: 'Using Concerns', link: '/docs/framework/concerns' },
          { text: 'Testing', link: '/docs/framework/testing' },
        ]
      },
      {
        text: 'Generation Providers',
        items: [
          { text: 'OpenAI', link: '/docs/generation-providers/openai-provider' },
          { text: 'Anthropic', link: '/docs/generation-providers/anthropic-provider' },
          { text: 'Ollama', link: '/docs/generation-providers/ollama-provider' },
          { text: 'OpenRouter', link: '/docs/generation-providers/open-router-provider' },
        ]
      },
      {
        text: 'Action Prompt',
        items: [
          { text: 'Messages', link: '/docs/action-prompt/messages' },
          { text: 'Actions', link: '/docs/action-prompt/actions' },
          { text: 'Prompts', link: '/docs/action-prompt/prompts' },
          { text: 'Tools', link: '/docs/action-prompt/tools' },
          { text: 'Tool Calling', link: '/docs/action-prompt/tool-calling' },
        ]
      },
      { text: 'Agents',
        items: [
          { text: 'Browser Use', link: '/docs/agents/browser-use-agent' },
          { text: 'Data Extraction', link: '/docs/agents/data-extraction-agent' },
          { text: 'Translation', link: '/docs/agents/translation-agent' },
        ]
      },
      { text: 'Active Agent',
        items: [
          // { text: 'Generative UI', link: '/docs/active-agent/generative-ui' },
          { text: 'Structured Output', link: '/docs/agents/data-extraction-agent#structured-output' },
          { text: 'Callbacks', link: '/docs/active-agent/callbacks' },
          { text: 'Generation', link: '/docs/active-agent/generation' },
          { text: 'Queued Generation', link: '/docs/active-agent/queued-generation' },
          // { text: 'Error Handling', link: '/docs/active-agent/error-handling' },
        ]
       },
    ],

    socialLinks: [
      { icon: 'bluesky', link: 'https://bsky.app/profile/activeagents.ai' },
      { icon: 'twitter', link: 'https://twitter.com/tonsoffun111' },
      { icon: 'discord', link: 'https://discord.gg/JRUxkkHKmh' },
      { icon: 'linkedin', link: 'https://www.linkedin.com/in/tonsoffun111/' },
      { icon: 'twitch', link: 'https://www.twitch.tv/tonsoffun111' },
      { icon: 'github', link: 'https://github.com/activeagents/activeagent' }
    ],
  }
})
