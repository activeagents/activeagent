<template>
  <div class="rails-demo-container">
    <div class="demo-header">
      <span class="status-dot" :class="{ active: isLoaded }"></span>
      <span>{{ title }}</span>
      <button @click="reload" class="reload-btn">↻</button>
    </div>
    <iframe
      :src="url"
      :title="title"
      @load="onLoad"
      class="rails-iframe"
      :style="{ height: height }"
    />
  </div>
</template>

<script setup>
import { ref } from 'vue'

const props = defineProps({
  url: {
    type: String,
    default: 'http://localhost:3000'
  },
  title: {
    type: String,
    default: 'Rails App Demo'
  },
  height: {
    type: String,
    default: '500px'
  }
})

const isLoaded = ref(false)
const iframeRef = ref(null)

const onLoad = () => {
  isLoaded.value = true
}

const reload = () => {
  isLoaded.value = false
  if (iframeRef.value) {
    iframeRef.value.src = props.url
  }
}
</script>

<style scoped>
.rails-demo-container {
  @apply rounded-lg overflow-hidden shadow-xl border border-gray-200;
}

.demo-header {
  @apply bg-gray-800 text-white px-4 py-2 flex items-center gap-2;
}

.status-dot {
  @apply w-3 h-3 rounded-full bg-red-500;
}

.status-dot.active {
  @apply bg-green-500;
}

.reload-btn {
  @apply ml-auto px-2 py-1 rounded hover:bg-gray-700 transition;
}

.rails-iframe {
  @apply w-full border-0;
  min-height: 400px;
}
</style>