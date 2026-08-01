<script setup lang="ts">
import { onMounted, ref, watch } from "vue";
import Sidebar from "./components/Sidebar.vue";
import TerminalPane from "./components/TerminalPane.vue";
import EmptyState from "./components/EmptyState.vue";
import { connect, createSession, sessions } from "./lib/control";

const activeId = ref<number | null>(null);

onMounted(connect);

// If the active session disappears (killed elsewhere, shell exited),
// fall back to the empty state.
watch(sessions, (list) => {
  if (activeId.value !== null && !list.some((s) => s.id === activeId.value))
    activeId.value = null;
});

async function onCreate(): Promise<void> {
  const created = await createSession();
  if (created) activeId.value = created.id;
}
</script>

<template>
  <div class="shell">
    <Sidebar
      :active-id="activeId"
      @select="(id: number) => (activeId = id)"
      @create="onCreate"
    />
    <main class="pane">
      <TerminalPane
        v-if="activeId !== null"
        :key="activeId"
        :session-id="activeId"
        @deselect="activeId = null"
      />
      <EmptyState v-else @create="onCreate" />
    </main>
  </div>
</template>

<style scoped>
.shell {
  display: grid;
  grid-template-columns: 280px 1fr;
  height: 100%;
}

.pane {
  min-width: 0;
  min-height: 0;
  display: flex;
  flex-direction: column;
  background: var(--bg);
}

@media (max-width: 760px) {
  .shell {
    grid-template-columns: 220px 1fr;
  }
}
</style>
