<script setup lang="ts">
import { motion } from "motion-v";
import logo from "../assets/logo.png";

const emit = defineEmits<{ create: [] }>();
</script>

<template>
  <div class="empty">
    <motion.div
      class="card"
      :initial="{ opacity: 0, y: 14, scale: 0.98 }"
      :animate="{ opacity: 1, y: 0, scale: 1 }"
      :transition="{ duration: 0.35, ease: 'easeOut' }"
    >
      <img class="logo" :src="logo" alt="TermWire" />
      <h1>Your terminals, unowned by windows</h1>
      <p>
        Sessions live in the TermWire runtime. Attach from here, from
        <code>tw</code>, or from anywhere — close the tab and the shell
        keeps running.
      </p>
      <motion.button
        class="cta"
        :while-press="{ scale: 0.97 }"
        :while-hover="{ scale: 1.02 }"
        @click="emit('create')"
      >
        Create a session
      </motion.button>
    </motion.div>
  </div>
</template>

<style scoped>
.empty {
  flex: 1;
  display: grid;
  place-items: center;
  padding: 24px;
}

.card {
  display: flex;
  flex-direction: column;
  align-items: center;
  text-align: center;
  max-width: 420px;
}

.logo {
  width: 108px;
  height: 108px;
  border-radius: 22px;
  border: 1px solid var(--border-strong);
  box-shadow: 0 12px 48px rgba(96, 92, 246, 0.22);
  margin-bottom: 26px;
}

h1 {
  font-size: 17px;
  margin: 0 0 10px;
  letter-spacing: 0.01em;
}

p {
  color: var(--text-muted);
  font-size: 12.5px;
  margin: 0 0 22px;
}

code {
  background: var(--bg-hover);
  border: 1px solid var(--border);
  border-radius: 5px;
  padding: 1px 5px;
  font-size: 11.5px;
}

.cta {
  padding: 10px 22px;
  border-radius: var(--radius);
  background: var(--gradient);
  color: #fff;
  font-weight: 700;
  font-size: 12.5px;
  box-shadow: 0 4px 18px rgba(96, 92, 246, 0.28);
}
</style>
