// https://vitepress.dev/guide/custom-theme
import { h } from 'vue'
import type { Theme } from 'vitepress'
import DefaultTheme from 'vitepress/theme'
import './style.css'
import 'virtual:group-icons.css'
import FeatureCards from './components/FeatureCards.vue'
// import GitHubStars from './components/GitHubStars.vue'

export default {
  extends: DefaultTheme,
  Layout: () => {
    return h(DefaultTheme.Layout, null, {
      // https://vitepress.dev/guide/extending-default-theme#layout-slots
      // 'nav-bar-content-after': () => h(GitHubStars)
    })
  },
  enhanceApp({ app, router, siteData }) {
    // Register components globally if needed
    app.component('FeatureCards', FeatureCards)
    // app.component('GitHubStars', GitHubStars)
  }
} satisfies Theme
