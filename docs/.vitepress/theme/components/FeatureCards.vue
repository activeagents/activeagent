<template>
  <div class="feature-grid">
    <a v-for="card in cards" :key="card.title" :href="card.link" class="feature-card">
      <!-- Icon handling -->
      <div class="feature-icon" v-if="card.icon" v-html="card.icon"></div>
      
      <div class="feature-content">
        <h3>{{ card.title }}</h3>
        <p>{{ card.details }}</p>
      </div>
    </a>
  </div>
</template>

<script setup>
defineProps({
  cards: {
    type: Array,
    required: true
  }
})
</script>

<style scoped>
.feature-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
  gap: 24px;
  margin: 32px 0;
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
  margin-bottom: 16px;
  font-size: 24px;
  display: flex;
  align-items: center;
}

/* Style for image elements inside the icon */
.feature-icon :deep(img) {
  width: 48px;
  height: 48px;
  object-fit: contain;
}

.feature-content h3 {
  font-size: 20px;
  font-weight: 600;
  margin-top: 0;
  margin-bottom: 12px;
}

.feature-content p {
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