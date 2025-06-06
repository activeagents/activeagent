import { defineConfig } from 'vitepress'

import {
  groupIconMdPlugin,
  groupIconVitePlugin,
  localIconLoader,
} from "vitepress-plugin-group-icons"

// https://vitepress.dev/reference/site-config
export default defineConfig({
  markdown: {
    config(md) {
      md.use(groupIconMdPlugin)
    },
  },
  base: '/activeagent/',
  vite: {
    plugins: [
      groupIconVitePlugin({
        customIcon: {
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
  ],
  cleanUrls: true,
  themeConfig: {
    search: {
      provider: 'local',
    },
    // https://vitepress.dev/reference/default-theme-config
    nav: [
      { text: 'Home', link: '/' },
      { text: 'Docs', link: '/docs' },
    ],
    sidebar: [
      {
        text: 'Rails AI Framework',
        link: '/docs/intro',
      },
      {
        text: 'Framework',
        link: '/docs/framework',
        items: [
          { text: 'Generation Provider', link: '/docs/framework/generation-provider' },
          { text: 'Action Prompt', link: '/docs/framework/action-prompt' },
          { text: 'Active Agent', link: '/docs/framework/active-agent' },
        ]
      },
      {
        text: 'Action Prompt',
        link: '/docs/action-prompt',
        items: [
          { text: 'Messages', link: '/docs/action-prompt/messages' },
          { text: 'Actions', link: '/docs/action-prompt/actions' },
          { text: 'Prompts', link: '/docs/action-prompt/prompts' },
        ]
      },
      { text: 'Active Agent', link: '/docs/active-agent',
        items: [
          { text: 'Callbacks', link: '/docs/active-agent/callbacks' },
          { text: 'Generation', link: '/docs/active-agent/generation' },
          { text: 'Queued Generation', link: '/docs/active-agent/queued-generation' },
          { text: 'Error Handling', link: '/docs/active-agent/error-handling' },
        ]
       },
      // {
      //   text: 'Framework',
      //   link: '/docs/framework',
      //   items: [
      //     { text: 'Agents', link: '/docs/framework/agents' },
      //     { text: 'Callbacks', link: '/docs/framework/callbacks' },
      //   ]
      // }
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
