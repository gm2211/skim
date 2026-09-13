import { useEffect, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import {
  getOfflineCacheStats,
  OFFLINE_PRELOAD_PROGRESS_EVENT,
  preloadArticlesForOffline,
  type OfflinePreloadProgress,
} from "../../services/commands";

const DEFAULT_LIMIT = 300;
let activePreload: Promise<OfflinePreloadProgress> | null = null;
let latestProgress: OfflinePreloadProgress | null = null;

export function OfflineReaderSettings() {
  const [limit, setLimit] = useState(() => Number(localStorage.getItem("offline-reader-limit")) || DEFAULT_LIMIT);
  const [cached, setCached] = useState<number | null>(null);
  const [progress, setProgress] = useState<OfflinePreloadProgress | null>(latestProgress);
  const [running, setRunning] = useState(activePreload !== null);
  const [message, setMessage] = useState<string | null>(null);

  useEffect(() => {
    getOfflineCacheStats().then((stats) => setCached(stats.extracted_articles)).catch(() => setCached(-1));
    const unlisten = listen<OfflinePreloadProgress>(OFFLINE_PRELOAD_PROGRESS_EVENT, (event) => {
      latestProgress = event.payload;
      setProgress(event.payload);
    });
    return () => { void unlisten.then((fn) => fn()); };
  }, []);

  const changeLimit = (value: number) => {
    const next = Math.max(25, Math.min(1_000, Math.round(value / 25) * 25));
    setLimit(next);
    localStorage.setItem("offline-reader-limit", String(next));
  };

  const preload = async () => {
    setRunning(true);
    setMessage(null);
    setProgress({ completed: 0, total: 0, cached: 0, already_ready: 0, failed: 0, current_title: null });
    try {
      activePreload = preloadArticlesForOffline(limit);
      const result = await activePreload;
      latestProgress = result;
      setProgress(result);
      const ready = result.cached + result.already_ready;
      setMessage(`Offline preload finished: ${ready} ready, ${result.cached} newly cached, ${result.failed} failed.`);
      setCached((await getOfflineCacheStats()).extracted_articles);
    } catch (error) {
      setMessage(`Offline preload failed: ${error instanceof Error ? error.message : String(error)}`);
    } finally { activePreload = null; setRunning(false); }
  };

  const fraction = progress?.total ? progress.completed / progress.total : 0;
  return (
    <section className="rounded-xl border border-border bg-bg-tertiary" style={{ padding: 20 }} aria-labelledby="offline-reader-title">
      <h3 id="offline-reader-title" className="text-text-primary" style={{ fontSize: 16, fontWeight: 600 }}>Offline reading</h3>
      <p className="text-text-secondary" style={{ marginTop: 6, fontSize: 13, lineHeight: 1.5 }}>
        {cached === null ? "Checking the reader cache…" : cached < 0 ? "Reader cache statistics are unavailable." : `${cached.toLocaleString()} extracted article${cached === 1 ? "" : "s"} cached. RSS article bodies are already stored locally.`}
      </p>
      <label className="flex flex-col gap-2" style={{ marginTop: 16 }}>
        <span className="text-text-primary" style={{ fontSize: 14, fontWeight: 600 }}>Preload limit: {limit.toLocaleString()} articles</span>
        <input aria-label="Offline preload limit" type="range" min={25} max={1000} step={25} value={limit} onChange={(event) => changeLimit(Number(event.target.value))} />
        <span className="text-text-muted" style={{ fontSize: 12 }}>Newest articles are prepared for offline reading.</span>
      </label>
      {running && progress && (
        <div style={{ marginTop: 16 }} aria-live="polite">
          <progress className="w-full" max={1} value={fraction} />
          <p className="text-text-secondary" style={{ marginTop: 6, fontSize: 12 }}>{progress.completed} of {progress.total} · {progress.cached} cached · {progress.already_ready} already ready · {progress.failed} failed</p>
          {progress.current_title && <p className="text-text-muted line-clamp-2" style={{ marginTop: 4, fontSize: 12 }}>{progress.current_title}</p>}
        </div>
      )}
      {message && <p role="status" className="text-text-secondary" style={{ marginTop: 12, fontSize: 13 }}>{message}</p>}
      <button onClick={preload} disabled={running} className="rounded-lg bg-accent text-bg-primary hover:bg-accent-hover disabled:opacity-50" style={{ minHeight: 44, marginTop: 16, padding: "10px 16px", fontSize: 14, fontWeight: 600 }}>
        {running ? "Preloading articles…" : "Preload articles"}
      </button>
    </section>
  );
}
