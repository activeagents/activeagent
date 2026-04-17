// https://vitepress.dev/guide/custom-theme
import { h } from 'vue'
import type { Theme } from 'vitepress'
import DefaultTheme from 'vitepress/theme'
import './style.css'
import 'virtual:group-icons.css'
import FeatureCards from './components/FeatureCards.vue'
import CursorGradient from './components/CursorGradient.vue'
import InteractiveLogo from './components/InteractiveLogo.vue'
import { enhanceAppWithTabs } from 'vitepress-plugin-tabs/client'

export default {
  extends: DefaultTheme,
  Layout: () => {
    return h(DefaultTheme.Layout, null, {
      // https://vitepress.dev/guide/extending-default-theme#layout-slots
      // 'nav-bar-content-after': () => h(GitHubStars)
      'layout-top': () => h(CursorGradient),
      'home-hero-image': () => h(InteractiveLogo, { size: 320 })
    })
  },
  enhanceApp({ app, router, siteData }) {
    // Register components globally if needed
    app.component('FeatureCards', FeatureCards)
    app.component('CursorGradient', CursorGradient)
    app.component('InteractiveLogo', InteractiveLogo)
    enhanceAppWithTabs(app)
  }
} satisfies Theme
