import { useEffect, useState, type CSSProperties } from "react";
import { listen } from "@tauri-apps/api/event";
import {
  getOfflineCacheStats,
  OFFLINE_PRELOAD_PROGRESS_EVENT,
  type OfflinePreloadProgress,
} from "../../services/commands";
import {
  latestPreloadProgress,
  offlineAutoPreloadEnabled,
  offlinePreloadLimit,
  offlinePreloadRunning,
  rememberPreloadProgress,
  setOfflineAutoPreload,
  setOfflinePreloadLimit,
  startOfflinePreload,
} from "../../lib/offlinePreload";

function formatBytes(bytes: number): string {
  if (bytes < 1024 * 1024) return `${Math.max(0, Math.round(bytes / 1024))} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(bytes < 10 * 1024 * 1024 ? 1 : 0)} MB`;
}

export function OfflineReaderSettings() {
  const [limit, setLimit] = useState(offlinePreloadLimit);
  const [auto, setAuto] = useState(offlineAutoPreloadEnabled);
  const [cached, setCached] = useState<number | null>(null);
  const [imageBytes, setImageBytes] = useState<number | null>(null);
  const [progress, setProgress] = useState<OfflinePreloadProgress | null>(latestPreloadProgress);
  const [running, setRunning] = useState(offlinePreloadRunning);
  const [message, setMessage] = useState<string | null>(null);

  useEffect(() => {
    getOfflineCacheStats()
      .then((stats) => { setCached(stats.extracted_articles); setImageBytes(stats.image_bytes ?? null); })
      .catch(() => setCached(-1));
    const unlisten = listen<OfflinePreloadProgress>(OFFLINE_PRELOAD_PROGRESS_EVENT, (event) => {
      rememberPreloadProgress(event.payload);
      setProgress(event.payload);
    });
    return () => { void unlisten.then((fn) => fn()); };
  }, []);

  const changeLimit = (value: number) => {
    const next = Math.max(25, Math.min(1_000, Math.round(value / 25) * 25));
    setLimit(next);
    setOfflinePreloadLimit(next);
  };

  const changeAuto = (next: boolean) => {
    setAuto(next);
    setOfflineAutoPreload(next);
  };

  const preload = async () => {
    setRunning(true);
    setMessage(null);
    setProgress({ completed: 0, total: 0, cached: 0, already_ready: 0, failed: 0, current_title: null });
    try {
      const result = await startOfflinePreload(limit);
      setProgress(result);
      const ready = result.cached + result.already_ready;
      setMessage(`Offline preload finished: ${ready} ready, ${result.cached} newly cached, ${result.failed} failed.`);
      const stats = await getOfflineCacheStats();
      setCached(stats.extracted_articles);
      setImageBytes(stats.image_bytes ?? null);
    } catch (error) {
      setMessage(`Offline preload failed: ${error instanceof Error ? error.message : String(error)}`);
    } finally { setRunning(false); }
  };

  const fraction = progress?.total ? progress.completed / progress.total : 0;
  return (
    <section className="settings-card" style={{ padding: 20 }} aria-labelledby="offline-reader-title">
      <h3 id="offline-reader-title" className="text-text-primary" style={{ fontSize: 16, fontWeight: 600 }}>Offline reading</h3>
      <p className="text-text-secondary" style={{ marginTop: 6, fontSize: 13, lineHeight: 1.5 }}>
        {cached === null ? "Checking the reader cache…" : cached < 0 ? "Reader cache statistics are unavailable." : `${cached.toLocaleString()} extracted article${cached === 1 ? "" : "s"} cached${imageBytes ? `, with ${formatBytes(imageBytes)} of pictures` : ""}. RSS article bodies are already stored locally.`}
      </p>
      <label className="flex flex-col gap-2" style={{ marginTop: 16 }}>
        <span className="text-text-primary" style={{ fontSize: 14, fontWeight: 600 }}>Preload limit: {limit.toLocaleString()} articles</span>
        <input aria-label="Offline preload limit" type="range" min={25} max={1000} step={25} value={limit} onChange={(event) => changeLimit(Number(event.target.value))} style={{ "--fill": `${((limit - 25) / (1000 - 25)) * 100}%` } as CSSProperties} />
        <span className="text-text-muted" style={{ fontSize: 12 }}>Newest articles are prepared for offline reading, pictures included (up to 300 MB of pictures; the oldest are dropped first).</span>
      </label>
      <label className="settings-row" style={{ marginTop: 16 }}>
        <input type="checkbox" checked={auto} onChange={(event) => changeAuto(event.target.checked)} />
        <span className="flex flex-col gap-1">
          <span className="text-text-primary" style={{ fontSize: 14, fontWeight: 600 }}>Save new articles after each refresh</span>
          <span className="text-text-muted" style={{ fontSize: 12 }}>Runs in the background so the latest articles open with no connection.</span>
        </span>
      </label>
      {running && progress && (
        <div style={{ marginTop: 16 }} aria-live="polite">
          <progress className="w-full" max={1} value={fraction} />
          <p className="text-text-secondary" style={{ marginTop: 6, fontSize: 12 }}>{progress.completed} of {progress.total} · {progress.cached} cached · {progress.already_ready} already ready · {progress.failed} failed</p>
          {progress.current_title && <p className="text-text-muted line-clamp-2" style={{ marginTop: 4, fontSize: 12 }}>{progress.current_title}</p>}
        </div>
      )}
      {message && <p role="status" className="text-text-secondary" style={{ marginTop: 12, fontSize: 13 }}>{message}</p>}
      <button onClick={preload} disabled={running} className="settings-btn settings-btn-primary" style={{ marginTop: 16 }}>
        {running ? "Preloading articles…" : "Preload articles"}
      </button>
    </section>
  );
}
