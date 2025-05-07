import { defineConfig } from 'vitepress'

import {
  groupIconMdPlugin,
  groupIconVitePlugin,
} from "vitepress-plugin-group-icons"

const markdown = {
  config(md) {
    md.use(groupIconMdPlugin)
  },
  codeTransformers: [transformerTwoslash()],
  // Explicitly load these languages for types hightlighting
  languages: ["js", "jsx", "ts", "tsx", "bash", "shell", "ruby", "html", "erb"],
}

// https://vp.yuy1n.io/features.html
// https://github.com/vscode-icons/vscode-icons/wiki/ListOfFiles
const groupIconPlugin = groupIconVitePlugin({
  customIcon: {
  },
})
// https://vitepress.dev/reference/site-config
export default defineConfig({
  markdown: {
    config(md) {
      md.use(groupIconMdPlugin)
    },
  },
  vite: {
    plugins: [
      groupIconVitePlugin({
        defaultLabels: [
          'npm',
          'yarn',
          'pnpm',
          'bun',
          'deno',
        ],
      })
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
    // https://vitepress.dev/reference/default-theme-config
    nav: [
      { text: 'Home', link: '/' },
      { text: 'Docs', link: '/docs' },

    ],
    sidebar: [
      {
        text: 'Documentation',
        items: [
          { text: 'Framework', link: '/docs/framework' },
          { text: 'Getting Started', link: '/docs/getting-started' }
        ]
      },
      {
        text: 'Framework',
        items: [
          { text: 'Agents', link: '/docs/framework/agents' },
          { text: 'Actions', link: '/docs/framework/actions' },
          { text: 'Prompts', link: '/docs/framework/prompts' },
          { text: 'Callbacks', link: '/docs/framework/callbacks' },
        ]
      }
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
