<template>
  <div ref="gradientContainer" class="cursor-gradient-container"></div>
</template>

<script setup lang="ts">
import { onMounted, onUnmounted, ref } from 'vue'

const gradientContainer = ref<HTMLElement>()

let mouseX = 0
let mouseY = 0
let currentX = 0
let currentY = 0
let animationFrame: number

const lerp = (start: number, end: number, factor: number) => {
  return start + (end - start) * factor
}

const updateGradient = () => {
  // Smooth interpolation for fluid movement
  currentX = lerp(currentX, mouseX, 0.1)
  currentY = lerp(currentY, mouseY, 0.1)
  
  // Update CSS custom properties
  document.documentElement.style.setProperty('--cursor-x', `${currentX}%`)
  document.documentElement.style.setProperty('--cursor-y', `${currentY}%`)
  
  animationFrame = requestAnimationFrame(updateGradient)
}

const handleMouseMove = (e: MouseEvent) => {
  // Calculate mouse position as percentage
  mouseX = (e.clientX / window.innerWidth) * 100
  mouseY = (e.clientY / window.innerHeight) * 100
}

onMounted(() => {
  // Set initial position to center
  mouseX = 50
  mouseY = 50
  currentX = 50
  currentY = 50
  
  // Start animation loop
  updateGradient()
  
  // Add mouse move listener
  window.addEventListener('mousemove', handleMouseMove)
  
  // Add touch support for mobile
  window.addEventListener('touchmove', (e) => {
    if (e.touches.length > 0) {
      const touch = e.touches[0]
      mouseX = (touch.clientX / window.innerWidth) * 100
      mouseY = (touch.clientY / window.innerHeight) * 100
    }
  })
})

onUnmounted(() => {
  window.removeEventListener('mousemove', handleMouseMove)
  if (animationFrame) {
    cancelAnimationFrame(animationFrame)
  }
})
</script>

<style scoped>
.cursor-gradient-container {
  position: fixed;
  top: 0;
  left: 0;
  width: 100%;
  height: 100%;
  pointer-events: none;
  z-index: -1;
}
</style>