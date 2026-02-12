import { defineConfig } from 'vitepress'
import { tabsMarkdownPlugin } from 'vitepress-plugin-tabs'

import {
  groupIconMdPlugin,
  groupIconVitePlugin,
  localIconLoader,
} from "vitepress-plugin-group-icons"

import versions from './versions.json'

// Build version dropdown items with absolute URLs for cross-version navigation
// This forces full page reload instead of client-side routing
const versionItems = versions.versions.map(v => ({
  text: v.label,
  link: v.path.startsWith('/v')
    ? `https://docs.activeagents.ai${v.path}`
    : v.path
}))

// Support versioned builds via VITEPRESS_BASE env var
// @ts-ignore - process.env is available at build time
const base: string = process.env.VITEPRESS_BASE || '/'

// https://vitepress.dev/reference/site-config
export default defineConfig({
  base,
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
    ['link', { rel: 'icon', type: 'image/svg+xml', href: '/activeagent-logo.svg' }],
    ['link', { rel: 'icon', type: 'image/png', href: '/activeagent.png' }],
    ['link', { rel: 'icon', href: '/favicon-16x16.png', sizes: '16x16' }],
    ['link', { rel: 'icon', href: '/favicon-32x32.png', sizes: '32x32' }],
    ['link', { rel: 'apple-touch-icon', href: '/apple-touch-icon.png' }],
    ['meta', { property: 'og:image', content: '/social.png' }],
    ['meta', { property: 'og:title', content: 'Active Agent' }],
    ['meta', { property: 'og:description', content: 'The AI framework for Rails with less code & more fun.' }],
    ['meta', { property: 'og:url', content: 'https://activeagents.ai' }],
    ['meta', { property: 'og:type', content: 'website' }],
    ['script', { async: '', defer: '', src: 'https://buttons.github.io/buttons.js' }],
    ['link', { rel: 'help', type: 'text/markdown', href: '/llms.txt', title: 'LLM Documentation' }]
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
      { text: 'Docs', link: '/framework' },
      {
        text: `v${versions.current}`,
        items: versionItems
      },
      { text: 'GitHub', link: 'https://github.com/activeagents/activeagent' }
    ],
    sidebar: [
      {
        text: 'Overview',
        link: '/framework',
      },
      {
        text: 'Getting Started',
        link: '/getting_started',
      },
      {
        text: 'Framework',
        items: [
          { text: 'Agents', link: '/agents' },
          { text: 'Providers', link: '/providers' },
          { text: 'Configuration', link: '/framework/configuration' },
          { text: 'Instrumentation', link: '/framework/instrumentation' },
          { text: 'Retries', link: '/framework/retries' },
          { text: 'Rails Integration', link: '/framework/rails' },
          { text: 'Testing', link: '/framework/testing' },
        ]
      },
      { text: 'Agents',
        items: [
          { text: 'Actions', link: '/actions' },
          { text: 'Generation', link: '/agents/generation' },
          { text: 'Instructions', link: '/agents/instructions' },
          { text: 'Streaming', link: '/agents/streaming' },
          { text: 'Callbacks', link: '/agents/callbacks' },
          { text: 'Error Handling', link: '/agents/error_handling' },
        ]
      },
      {
        text: 'Actions',
        items: [
          { text: 'Messages', link: '/actions/messages' },
          { text: 'Embeddings', link: '/actions/embeddings' },
          { text: 'Tools', link: '/actions/tools' },
          { text: 'MCPs', link: '/actions/mcps' },
          { text: 'Structured Output', link: '/actions/structured_output' },
          { text: 'Usage', link: '/actions/usage' },
        ]
      },
      {
        text: 'Providers',
        items: [
          { text: 'Anthropic', link: '/providers/anthropic' },
          { text: 'Ollama', link: '/providers/ollama' },
          { text: 'OpenAI', link: '/providers/open_ai' },
          { text: 'OpenRouter', link: '/providers/open_router' },
          { text: 'Mock', link: '/providers/mock' },
        ]
      },
      { text: 'Examples',
        items: [
          // { text: 'Browser Use', link: '/examples/browser-use-agent' },
          { text: 'Data Extraction', link: '/examples/data_extraction_agent' },
          // { text: 'Translation', link: '/examples/translation-agent' },
        ]
      },
      { text: 'Contributing',
        items: [
          { text: 'Documentation', link: '/contributing/documentation' },
          { text: 'LLMs.txt', link: '/llms_txt' },
        ]
      },
    ],
    outline: {
      level: 'deep'
    },

    socialLinks: [
      { icon: 'bluesky', link: 'https://bsky.app/profile/activeagents.ai' },
      { icon: 'twitter', link: 'https://twitter.com/tonsoffun111' },
      { icon: 'discord', link: 'https://discord.gg/JRUxkkHKmh' },
      { icon: 'linkedin', link: 'https://www.linkedin.com/in/tonsoffun111/' },
      { icon: 'twitch', link: 'https://www.twitch.tv/tonsoffun111' },
      { icon: 'github', link: 'https://github.com/activeagents/activeagent' }
    ],
  },
  lastUpdated: true
})
