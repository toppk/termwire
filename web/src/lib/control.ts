// Control-plane client: one persistent WebSocket to termwire-webd's
// /ws/control, which bridges to the daemon's JSON control socket.
// Requests and responses are strictly ordered on the daemon side, so
// a FIFO of resolvers is enough to pair them.

import { ref } from "vue";

export interface SessionInfo {
  id: number;
  pid: number;
  cols: number;
  rows: number;
  created_unix: number;
  socket_path: string;
}

export interface ControlResponse {
  ok: boolean;
  msg?: string;
  session?: SessionInfo;
  sessions?: SessionInfo[];
}

type ControlRequest =
  | { op: "create_session"; cols?: number; rows?: number }
  | { op: "list_sessions" }
  | { op: "kill_session"; id: number };

const POLL_MS = 4000;
const RECONNECT_MS = 1500;

export const sessions = ref<SessionInfo[]>([]);
export const connected = ref(false);

let ws: WebSocket | null = null;
let pending: Array<(r: ControlResponse) => void> = [];
let pollTimer: ReturnType<typeof setInterval> | undefined;

function wsUrl(path: string): string {
  const proto = location.protocol === "https:" ? "wss:" : "ws:";
  return `${proto}//${location.host}${path}`;
}

export function connect(): void {
  if (ws) return;
  ws = new WebSocket(wsUrl("/ws/control"));

  ws.onopen = () => {
    connected.value = true;
    void refresh();
    pollTimer = setInterval(() => void refresh(), POLL_MS);
  };

  ws.onmessage = (ev: MessageEvent<string>) => {
    const resolve = pending.shift();
    if (!resolve) return;
    try {
      resolve(JSON.parse(ev.data) as ControlResponse);
    } catch {
      resolve({ ok: false, msg: "bad response" });
    }
  };

  ws.onclose = () => {
    connected.value = false;
    ws = null;
    clearInterval(pollTimer);
    for (const resolve of pending) resolve({ ok: false, msg: "disconnected" });
    pending = [];
    setTimeout(connect, RECONNECT_MS);
  };

  ws.onerror = () => ws?.close();
}

function request(req: ControlRequest): Promise<ControlResponse> {
  return new Promise((resolve) => {
    if (!ws || ws.readyState !== WebSocket.OPEN) {
      resolve({ ok: false, msg: "not connected" });
      return;
    }
    pending.push(resolve);
    ws.send(JSON.stringify(req));
  });
}

export async function refresh(): Promise<void> {
  const r = await request({ op: "list_sessions" });
  if (r.ok) sessions.value = (r.sessions ?? []).sort((a, b) => a.id - b.id);
}

export async function createSession(): Promise<SessionInfo | null> {
  const r = await request({ op: "create_session", cols: 80, rows: 24 });
  await refresh();
  return r.ok ? (r.session ?? null) : null;
}

export async function killSession(id: number): Promise<void> {
  await request({ op: "kill_session", id });
  // The daemon reaps asynchronously; poll a moment later too.
  await refresh();
  setTimeout(() => void refresh(), 600);
}

export function sessionWsUrl(id: number): string {
  return wsUrl(`/ws/session/${id}`);
}

export function formatAge(createdUnix: number, nowMs: number): string {
  if (!createdUnix) return "";
  const s = Math.max(0, Math.floor(nowMs / 1000) - createdUnix);
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`;
  return `${Math.floor(s / 86400)}d ${Math.floor((s % 86400) / 3600)}h`;
}
