<template>
  <Layout>
    <template #doc-before>
      <div v-if="frontmatter.cards" class="feature-section">
        <div class="feature-grid">
          <a 
            v-for="card in frontmatter.cards" 
            :key="card.title" 
            :href="card.link" 
            class="feature-card"
          >
            <div v-if="card.icon" class="feature-icon">{{ card.icon }}</div>
            <h3>{{ card.title }}</h3>
            <p>{{ card.description }}</p>
          </a>
        </div>
      </div>
    </template>
  </Layout>
</template>

<script setup>
import { useData } from 'vitepress'
import DefaultTheme from 'vitepress/theme'

const { Layout } = DefaultTheme
const { frontmatter } = useData()
</script>

<style scoped>
.feature-section {
  margin-bottom: 48px;
}

.feature-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
  gap: 24px;
}

.feature-card {
  display: flex;
  flex-direction: column;
  padding: 24px;
  border-radius: 8px;
  background-color: var(--vp-c-bg-soft);
  border: 1px solid var(--vp-c-divider);
  color: var(--vp-c-text-1);
  text-decoration: none;
  transition: all 0.2s;
}

.feature-card:hover {
  border-color: var(--vp-c-brand);
  background-color: var(--vp-c-bg);
}

.feature-icon {
  font-size: 24px;
  margin-bottom: 12px;
}

.feature-card h3 {
  font-size: 20px;
  font-weight: 600;
  margin-top: 0;
  margin-bottom: 12px;
}

.feature-card p {
  font-size: 14px;
  line-height: 1.5;
  color: var(--vp-c-text-2);
  margin: 0;
}

@media (max-width: 640px) {
  .feature-grid {
    grid-template-columns: 1fr;
  }
}
</style>