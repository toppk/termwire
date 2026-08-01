<script setup lang="ts">
import { onMounted, onUnmounted, ref } from "vue";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { AnimatePresence, motion } from "motion-v";
import { killSession, sessionWsUrl } from "../lib/control";

const props = defineProps<{ sessionId: number }>();
const emit = defineEmits<{ deselect: [] }>();

const termEl = ref<HTMLDivElement | null>(null);
const size = ref("");
const state = ref<"connecting" | "connected" | "ended">("connecting");

let term: Terminal;
let fit: FitAddon;
let ws: WebSocket;
let observer: ResizeObserver;
const encoder = new TextEncoder();

onMounted(() => {
  term = new Terminal({
    fontFamily: "'JetBrains Mono Variable', ui-monospace, monospace",
    fontSize: 13.5,
    lineHeight: 1.25,
    cursorBlink: true,
    scrollback: 10000,
    allowProposedApi: true,
    theme: {
      background: "#0b0d14",
      foreground: "#dde3f0",
      cursor: "#8b5cf6",
      cursorAccent: "#0b0d14",
      selectionBackground: "rgba(122, 143, 255, 0.28)",
      black: "#1a1f2b",
      red: "#f87171",
      green: "#34d399",
      yellow: "#fbbf24",
      blue: "#60a5fa",
      magenta: "#a78bfa",
      cyan: "#22d3ee",
      white: "#cbd5e1",
      brightBlack: "#475069",
      brightRed: "#fca5a5",
      brightGreen: "#6ee7b7",
      brightYellow: "#fde68a",
      brightBlue: "#93c5fd",
      brightMagenta: "#c4b5fd",
      brightCyan: "#67e8f9",
      brightWhite: "#f1f5f9",
    },
  });
  fit = new FitAddon();
  term.loadAddon(fit);
  term.open(termEl.value!);

  ws = new WebSocket(sessionWsUrl(props.sessionId));
  ws.binaryType = "arraybuffer";

  ws.onopen = () => {
    state.value = "connected";
    doFit();
    // fit() only fires onResize when dimensions change, and earlier
    // resize events were dropped while the socket was still
    // connecting — always sync the PTY to our current size.
    sendResize(term.cols, term.rows);
    term.focus();
  };

  ws.onmessage = (ev: MessageEvent<ArrayBuffer>) => {
    term.write(new Uint8Array(ev.data));
  };

  ws.onclose = () => {
    if (state.value !== "ended") state.value = "ended";
  };

  term.onData((data) => {
    if (ws.readyState === WebSocket.OPEN) ws.send(encoder.encode(data));
  });

  term.onBinary((data) => {
    if (ws.readyState !== WebSocket.OPEN) return;
    const bytes = new Uint8Array(data.length);
    for (let i = 0; i < data.length; i++) bytes[i] = data.charCodeAt(i) & 0xff;
    ws.send(bytes);
  });

  term.onResize(({ cols, rows }) => sendResize(cols, rows));

  observer = new ResizeObserver(doFit);
  observer.observe(termEl.value!);
});

onUnmounted(() => {
  observer?.disconnect();
  ws?.close();
  term?.dispose();
});

function doFit(): void {
  if (!termEl.value || termEl.value.clientWidth === 0) return;
  fit.fit();
}

function sendResize(cols: number, rows: number): void {
  size.value = `${cols}×${rows}`;
  if (ws.readyState === WebSocket.OPEN)
    ws.send(JSON.stringify({ resize: { cols, rows } }));
}

async function onKill(): Promise<void> {
  await killSession(props.sessionId);
  emit("deselect");
}
</script>

<template>
  <div class="wrap">
    <header class="bar">
      <div class="bar-left">
        <span class="dot" :class="state" />
        <span class="title">session {{ sessionId }}</span>
        <span class="chip" v-if="size">{{ size }}</span>
      </div>
      <div class="bar-right">
        <button class="bar-btn" title="Detach (session keeps running)" @click="emit('deselect')">
          detach
        </button>
        <button class="bar-btn danger" title="Kill session" @click="onKill">
          kill
        </button>
      </div>
    </header>

    <div class="term-outer">
      <div ref="termEl" class="term" />
      <AnimatePresence>
        <motion.div
          v-if="state === 'ended'"
          class="overlay"
          :initial="{ opacity: 0 }"
          :animate="{ opacity: 1 }"
          :transition="{ duration: 0.25 }"
        >
          <div class="overlay-card">
            <p class="overlay-title">session ended</p>
            <p class="overlay-sub">the shell exited or the session was killed</p>
            <button class="bar-btn" @click="emit('deselect')">back to sessions</button>
          </div>
        </motion.div>
      </AnimatePresence>
    </div>
  </div>
</template>

<style scoped>
.wrap {
  flex: 1;
  display: flex;
  flex-direction: column;
  min-height: 0;
}

.bar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 10px 16px;
  border-bottom: 1px solid var(--border);
  background: var(--bg-raised);
}

.bar-left {
  display: flex;
  align-items: center;
  gap: 10px;
}

.dot {
  width: 7px;
  height: 7px;
  border-radius: 50%;
  background: var(--text-faint);
}

.dot.connected {
  background: var(--ok);
  animation: pulse-dot 2.4s ease-out infinite;
}

.dot.ended {
  background: var(--danger);
}

.title {
  font-weight: 700;
  font-size: 12.5px;
}

.chip {
  color: var(--text-faint);
  font-size: 11px;
  border: 1px solid var(--border);
  border-radius: 99px;
  padding: 1px 8px;
}

.bar-right {
  display: flex;
  gap: 8px;
}

.bar-btn {
  color: var(--text-muted);
  font-size: 11.5px;
  border: 1px solid var(--border);
  border-radius: 7px;
  padding: 4px 10px;
  transition: color 0.12s ease, border-color 0.12s ease, background 0.12s ease;
}

.bar-btn:hover {
  color: var(--text);
  border-color: var(--border-strong);
  background: var(--bg-hover);
}

.bar-btn.danger:hover {
  color: var(--danger);
  border-color: rgba(248, 113, 113, 0.4);
  background: rgba(248, 113, 113, 0.1);
}

.term-outer {
  position: relative;
  flex: 1;
  min-height: 0;
  padding: 12px 4px 4px 12px;
}

.term {
  width: 100%;
  height: 100%;
}

.overlay {
  position: absolute;
  inset: 0;
  display: grid;
  place-items: center;
  background: rgba(11, 13, 20, 0.82);
  backdrop-filter: blur(2px);
}

.overlay-card {
  text-align: center;
}

.overlay-title {
  font-weight: 700;
  font-size: 14px;
  margin: 0 0 4px;
}

.overlay-sub {
  color: var(--text-muted);
  font-size: 12px;
  margin: 0 0 16px;
}
</style>
