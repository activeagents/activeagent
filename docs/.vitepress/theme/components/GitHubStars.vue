<template>
  <div class="github-stars">
    <a class="github-button"
      href="https://github.com/activeagents/activeagent"
      data-color-scheme="no-preference: light; light: light; dark: dark;"
      data-icon="octicon-star"
      data-size="large"
      data-show-count="true"
      aria-label="Star activeagents/activeagent on GitHub">
      Star
    </a>
  </div>
</template>

<style scoped>
.github-stars {
  display: inline-flex;
  margin-top: 0.25rem;
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

