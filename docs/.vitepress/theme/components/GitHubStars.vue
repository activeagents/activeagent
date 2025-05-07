<script setup>
import { ref, onMounted } from 'vue'

const stars = ref(null)
const repo = 'activeagents/activeagent' // Your GitHub repo

onMounted(async () => {
  try {
    const response = await fetch(`https://api.github.com/repos/${repo}`)
    const data = await response.json()
    stars.value = data.stargazers_count
  } catch (error) {
    console.error('Error fetching GitHub stars:', error)
  }
})
</script>

<template>
  <div class="github-stars">
    <a 
      :href="`https://github.com/${repo}`"
      target="_blank"
      rel="noopener noreferrer"
      class="github-stars-link"
    >
      <span class="github-stars-icon">★</span>
      <span v-if="stars !== null" class="github-stars-count">{{ stars }}</span>
      <span v-else>...</span>
      <span class="github-stars-text">Star</span>
    </a>
  </div>
</template>

<style scoped>
.github-stars {
  display: inline-flex;
  margin-left: 0.5rem;
}

.github-stars-link {
  display: flex;
  align-items: center;
  border: 1px solid var(--vp-c-divider);
  border-radius: 6px;
  padding: 0.25rem 0.75rem;
  font-size: 0.875rem;
  color: var(--vp-c-text-1);
  transition: 0.2s ease;
  text-decoration: none;
}

.github-stars-link:hover {
  background-color: var(--vp-c-gray-light-4);
  border-color: var(--vp-c-gray);
}

.github-stars-icon {
  color: #f9ce03;
  margin-right: 0.25rem;
}

.github-stars-count {
  margin-right: 0.25rem;
}

.github-stars-text {
  display: inline-block;
}

@media (max-width: 768px) {
  .github-stars-text {
    display: none;
  }
}
</style>