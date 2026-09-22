// Browser-side half of the dev bridge (see src-tauri/src/devbridge.rs).
//
// Tauri's IPC only exists inside a real webview, so `@tauri-apps/api` is dead
// in a plain browser tab. Everything it needs hangs off two globals, so this
// installs them and forwards each `invoke` to the bridge's HTTP endpoint.
// Nothing in src/ has to know the difference.
//
// Enable with `SKIM_DEV_BRIDGE=1 pnpm dev`, after starting the bridge with
// `cargo run --features devbridge -- --dev-bridge`.
(() => {
  const BRIDGE =
    document.currentScript?.dataset?.bridge || "http://127.0.0.1:1421";

  const callbacks = new Map();
  let nextCallbackId = 1;

  // `listen()` is resolved in the browser: the mock runtime delivers events by
  // evaluating JS in a webview that does not exist, so the bridge buffers them
  // and we poll instead.
  const listeners = new Map(); // eventId -> { event, handlerId }
  let nextEventId = 1;
  let eventCursor = 0;
  let pollTimer = null;

  function transformCallback(callback, once = false) {
    const id = nextCallbackId++;
    callbacks.set(id, { callback, once });
    return id;
  }

  function fire(id, payload) {
    const entry = callbacks.get(id);
    if (!entry) return;
    if (entry.once) callbacks.delete(id);
    entry.callback(payload);
  }

  async function pollEvents() {
    try {
      const res = await fetch(`${BRIDGE}/events?since=${eventCursor}`);
      const body = await res.json();
      eventCursor = body.next ?? eventCursor;
      for (const item of body.events ?? []) {
        for (const [eventId, listener] of listeners) {
          if (listener.event !== item.event) continue;
          fire(listener.handlerId, {
            event: item.event,
            id: eventId,
            payload: item.payload,
          });
        }
      }
    } catch {
      // The bridge may not be up yet; the next tick retries.
    }
  }

  function ensurePolling() {
    if (pollTimer || listeners.size === 0) return;
    pollTimer = setInterval(pollEvents, 400);
  }

  async function invoke(cmd, payload = {}) {
    if (cmd === "plugin:event|listen") {
      const eventId = nextEventId++;
      listeners.set(eventId, { event: payload.event, handlerId: payload.handler });
      // Start from "now" so a fresh listener doesn't replay old progress.
      if (listeners.size === 1) {
        const res = await fetch(`${BRIDGE}/events?since=${eventCursor}`).catch(
          () => null,
        );
        if (res) eventCursor = (await res.json()).next ?? eventCursor;
      }
      ensurePolling();
      return eventId;
    }
    if (cmd === "plugin:event|unlisten") {
      listeners.delete(payload.eventId);
      return null;
    }

    const res = await fetch(`${BRIDGE}/invoke`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ cmd, payload }),
    });
    if (!res.ok) throw new Error(`dev bridge ${cmd}: HTTP ${res.status}`);
    const body = await res.json();
    if (body.ok) return body.data;
    throw body.error;
  }

  window.__TAURI_INTERNALS__ = {
    invoke,
    transformCallback,
    convertFileSrc: (filePath) => filePath,
    metadata: { currentWindow: { label: "main" }, currentWebview: { label: "main" } },
    plugins: {},
    runCallback: fire,
  };

  window.__TAURI_EVENT_PLUGIN_INTERNALS__ = {
    unregisterListener(_event, eventId) {
      listeners.delete(eventId);
    },
  };

  window.__SKIM_DEV_BRIDGE__ = BRIDGE;
  console.info(`[skim] dev bridge active → ${BRIDGE}`);
})();
