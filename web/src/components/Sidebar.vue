<script setup lang="ts">
import { onMounted, onUnmounted, ref } from "vue";
import { AnimatePresence, motion } from "motion-v";
import logo from "../assets/logo.png";
import { connected, formatAge, killSession, sessions } from "../lib/control";

defineProps<{ activeId: number | null }>();
const emit = defineEmits<{ select: [id: number]; create: [] }>();

// Ticks so session ages stay fresh.
const now = ref(Date.now());
let timer: ReturnType<typeof setInterval>;
onMounted(() => (timer = setInterval(() => (now.value = Date.now()), 5000)));
onUnmounted(() => clearInterval(timer));

async function onKill(ev: MouseEvent, id: number): Promise<void> {
  ev.stopPropagation();
  await killSession(id);
}
</script>

<template>
  <aside class="sidebar">
    <div class="brand">
      <img class="brand-logo" :src="logo" alt="" />
      <div>
        <div class="brand-name">TermWire</div>
        <div class="brand-sub">session runtime</div>
      </div>
    </div>

    <div class="section-label">
      Sessions
      <span class="count" v-if="sessions.length">{{ sessions.length }}</span>
    </div>

    <div class="list">
      <AnimatePresence>
        <motion.button
          v-for="s in sessions"
          :key="s.id"
          class="item"
          :class="{ active: s.id === activeId }"
          :initial="{ opacity: 0, y: 8 }"
          :animate="{ opacity: 1, y: 0 }"
          :exit="{ opacity: 0, x: -12 }"
          :transition="{ duration: 0.18 }"
          @click="emit('select', s.id)"
        >
          <span class="dot" />
          <span class="item-body">
            <span class="item-title">session {{ s.id }}</span>
            <span class="item-meta">
              {{ s.cols }}×{{ s.rows }}
              <template v-if="formatAge(s.created_unix, now)">
                · {{ formatAge(s.created_unix, now) }}</template>
            </span>
          </span>
          <span
            class="item-kill"
            role="button"
            title="Kill session"
            @click="onKill($event, s.id)"
            >✕</span>
        </motion.button>
      </AnimatePresence>

      <p v-if="!sessions.length" class="list-empty">
        No sessions running.
      </p>
    </div>

    <motion.button
      class="new-btn"
      :while-press="{ scale: 0.97 }"
      :while-hover="{ scale: 1.015 }"
      @click="emit('create')"
    >
      + New session
    </motion.button>

    <div class="status">
      <span class="status-dot" :class="{ off: !connected }" />
      {{ connected ? "runtime connected" : "runtime offline" }}
    </div>
  </aside>
</template>

<style scoped>
.sidebar {
  display: flex;
  flex-direction: column;
  background: var(--bg-raised);
  border-right: 1px solid var(--border);
  padding: 18px 14px 14px;
  min-height: 0;
}

.brand {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 2px 6px 18px;
}

.brand-logo {
  width: 42px;
  height: 42px;
  border-radius: 10px;
  border: 1px solid var(--border-strong);
}

.brand-name {
  font-weight: 700;
  font-size: 15px;
  letter-spacing: 0.01em;
  background: var(--gradient);
  -webkit-background-clip: text;
  background-clip: text;
  color: transparent;
}

.brand-sub {
  color: var(--text-faint);
  font-size: 11px;
}

.section-label {
  display: flex;
  align-items: center;
  gap: 8px;
  color: var(--text-faint);
  font-size: 11px;
  text-transform: uppercase;
  letter-spacing: 0.12em;
  padding: 0 6px 8px;
}

.count {
  background: var(--bg-hover);
  border: 1px solid var(--border);
  border-radius: 99px;
  padding: 0 7px;
  font-size: 10.5px;
  color: var(--text-muted);
}

.list {
  flex: 1;
  overflow-y: auto;
  display: flex;
  flex-direction: column;
  gap: 4px;
  min-height: 0;
}

.item {
  display: flex;
  align-items: center;
  gap: 10px;
  width: 100%;
  text-align: left;
  padding: 9px 10px;
  border-radius: var(--radius);
  border: 1px solid transparent;
  color: var(--text);
  transition: background 0.12s ease, border-color 0.12s ease;
}

.item:hover {
  background: var(--bg-hover);
}

.item.active {
  background: var(--bg-hover);
  border-color: var(--border-strong);
}

.dot {
  width: 7px;
  height: 7px;
  border-radius: 50%;
  background: var(--ok);
  flex-shrink: 0;
  animation: pulse-dot 2.4s ease-out infinite;
}

.item-body {
  display: flex;
  flex-direction: column;
  min-width: 0;
  flex: 1;
}

.item-title {
  font-weight: 600;
  font-size: 12.5px;
}

.item-meta {
  color: var(--text-faint);
  font-size: 11px;
}

.item-kill {
  color: var(--text-faint);
  font-size: 11px;
  padding: 3px 6px;
  border-radius: 6px;
  opacity: 0;
  transition: opacity 0.12s ease, color 0.12s ease, background 0.12s ease;
}

.item:hover .item-kill {
  opacity: 1;
}

.item-kill:hover {
  color: var(--danger);
  background: rgba(248, 113, 113, 0.12);
}

.list-empty {
  color: var(--text-faint);
  font-size: 12px;
  padding: 8px 6px;
}

.new-btn {
  margin-top: 12px;
  padding: 10px;
  border-radius: var(--radius);
  background: var(--gradient);
  color: #fff;
  font-weight: 700;
  font-size: 12.5px;
  letter-spacing: 0.02em;
  box-shadow: 0 4px 18px rgba(96, 92, 246, 0.28);
}

.status {
  display: flex;
  align-items: center;
  gap: 7px;
  color: var(--text-faint);
  font-size: 11px;
  padding: 14px 6px 0;
}

.status-dot {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: var(--ok);
}

.status-dot.off {
  background: var(--danger);
}
</style>
