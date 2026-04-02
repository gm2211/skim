import { useState } from "react";
import { useAddFeed } from "../../hooks/useFeeds";
import { useUiStore } from "../../stores/uiStore";
import { importFeedly, feedlyPreview } from "../../services/commands";
import type { FeedlySubscription, FeedlyImportResult } from "../../services/types";
import { useQueryClient } from "@tanstack/react-query";

type Tab = "url" | "feedly";

export function AddFeedDialog() {
  const [tab, setTab] = useState<Tab>("url");
  const setShowAddFeed = useUiStore((s) => s.setShowAddFeed);

  return (
    <div className="fixed inset-0 bg-black/60 backdrop-blur-sm flex items-center justify-center z-50">
      <div
        className="border border-white/10 rounded-2xl w-full max-w-md mx-4 shadow-2xl overflow-hidden"
        style={{ background: "rgba(22, 27, 34, 0.95)" }}
      >
        <div className="flex items-center justify-between" style={{ padding: "20px 24px 0" }}>
          <h2 style={{ fontSize: 18, fontWeight: 600 }} className="text-text-primary">Add Feed</h2>
          <button
            onClick={() => setShowAddFeed(false)}
            className="text-text-muted hover:text-text-primary p-1 rounded-lg hover:bg-white/10 transition-colors"
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M18 6L6 18M6 6l12 12" />
            </svg>
          </button>
        </div>

        {/* Tab bar */}
        <div className="flex gap-1" style={{ padding: "12px 24px 0" }}>
          <button
            onClick={() => setTab("url")}
            className={`rounded-lg transition-colors ${
              tab === "url" ? "bg-white/10 text-text-primary" : "text-text-muted hover:text-text-primary"
            }`}
            style={{ padding: "6px 14px", fontSize: 13, fontWeight: 500 }}
          >
            Feed URL
          </button>
          <button
            onClick={() => setTab("feedly")}
            className={`rounded-lg transition-colors ${
              tab === "feedly" ? "bg-white/10 text-text-primary" : "text-text-muted hover:text-text-primary"
            }`}
            style={{ padding: "6px 14px", fontSize: 13, fontWeight: 500 }}
          >
            Import from Feedly
          </button>
        </div>

        {tab === "url" ? <UrlTab /> : <FeedlyTab />}
      </div>
    </div>
  );
}

function UrlTab() {
  const [url, setUrl] = useState("");
  const addFeed = useAddFeed();
  const setShowAddFeed = useUiStore((s) => s.setShowAddFeed);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!url.trim()) return;
    try {
      await addFeed.mutateAsync(url.trim());
      setShowAddFeed(false);
    } catch {
      // error shown via addFeed.error
    }
  };

  return (
    <form onSubmit={handleSubmit} style={{ padding: "16px 24px 24px" }}>
      <div style={{ marginBottom: 20 }}>
        <label className="block text-text-secondary" style={{ fontSize: 13, marginBottom: 8 }}>
          Feed URL
        </label>
        <input
          type="url"
          value={url}
          onChange={(e) => setUrl(e.target.value)}
          placeholder="https://example.com/feed.xml"
          autoFocus
          className="w-full border border-white/10 rounded-xl text-text-primary placeholder-text-muted focus:outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/30 transition-colors"
          style={{
            background: "rgba(255, 255, 255, 0.05)",
            padding: "12px 16px",
            fontSize: 15,
          }}
        />
      </div>

      {addFeed.isError && (
        <div
          className="rounded-xl border border-danger/30 text-danger"
          style={{ padding: "12px 16px", marginBottom: 20, fontSize: 14, background: "rgba(248, 81, 73, 0.1)" }}
        >
          {String(addFeed.error instanceof Error ? addFeed.error.message : addFeed.error)}
        </div>
      )}

      <div className="flex justify-end gap-3">
        <button
          type="button"
          onClick={() => useUiStore.getState().setShowAddFeed(false)}
          className="text-text-secondary hover:text-text-primary rounded-xl hover:bg-white/5 transition-colors"
          style={{ padding: "10px 20px", fontSize: 14 }}
        >
          Cancel
        </button>
        <button
          type="submit"
          disabled={addFeed.isPending || !url.trim()}
          className="bg-accent text-white rounded-xl hover:bg-accent-hover disabled:opacity-40 font-medium transition-colors"
          style={{ padding: "10px 24px", fontSize: 14 }}
        >
          {addFeed.isPending ? "Adding..." : "Add Feed"}
        </button>
      </div>
    </form>
  );
}

function FeedlyTab() {
  const [token, setToken] = useState("");
  const [previewing, setPreviewing] = useState(false);
  const [importing, setImporting] = useState(false);
  const [subs, setSubs] = useState<FeedlySubscription[] | null>(null);
  const [result, setResult] = useState<FeedlyImportResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const setShowAddFeed = useUiStore((s) => s.setShowAddFeed);
  const qc = useQueryClient();

  const handlePreview = async () => {
    if (!token.trim()) return;
    setPreviewing(true);
    setError(null);
    try {
      const data = await feedlyPreview(token.trim());
      setSubs(data);
    } catch (e) {
      setError(String(e instanceof Error ? e.message : e));
    } finally {
      setPreviewing(false);
    }
  };

  const handleImport = async () => {
    if (!token.trim()) return;
    setImporting(true);
    setError(null);
    try {
      const res = await importFeedly(token.trim());
      setResult(res);
      qc.invalidateQueries({ queryKey: ["feeds"] });
      qc.invalidateQueries({ queryKey: ["articles"] });
    } catch (e) {
      setError(String(e instanceof Error ? e.message : e));
    } finally {
      setImporting(false);
    }
  };

  return (
    <div style={{ padding: "16px 24px 24px" }}>
      <p className="text-text-muted" style={{ fontSize: 12, marginBottom: 12 }}>
        Get your Feedly developer token from{" "}
        <span className="text-accent">feedly.com/v3/auth/dev</span>.
        Paste it below to import your subscriptions.
      </p>

      <input
        type="password"
        value={token}
        onChange={(e) => { setToken(e.target.value); setSubs(null); setResult(null); }}
        placeholder="Feedly access token"
        className="w-full border border-white/10 rounded-xl text-text-primary placeholder-text-muted focus:outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/30 transition-colors"
        style={{
          background: "rgba(255, 255, 255, 0.05)",
          padding: "12px 16px",
          fontSize: 14,
          marginBottom: 12,
        }}
      />

      {error && (
        <div
          className="rounded-xl border border-danger/30 text-danger"
          style={{ padding: "10px 14px", marginBottom: 12, fontSize: 13, background: "rgba(248, 81, 73, 0.1)" }}
        >
          {error}
        </div>
      )}

      {result && (
        <div
          className="rounded-xl border border-green-500/30 text-green-400"
          style={{ padding: "10px 14px", marginBottom: 12, fontSize: 13, background: "rgba(34, 197, 94, 0.1)" }}
        >
          Imported {result.imported} feed{result.imported !== 1 ? "s" : ""}.
          {result.skipped > 0 && ` ${result.skipped} already existed.`}
          {result.errors.length > 0 && ` ${result.errors.length} error(s).`}
        </div>
      )}

      {subs && !result && (
        <div style={{ marginBottom: 12 }}>
          <p className="text-text-secondary" style={{ fontSize: 13, marginBottom: 8 }}>
            Found {subs.length} subscription{subs.length !== 1 ? "s" : ""}:
          </p>
          <div
            className="border border-white/10 rounded-xl overflow-y-auto"
            style={{ maxHeight: 200, background: "rgba(255,255,255,0.03)" }}
          >
            {subs.map((sub) => (
              <div key={sub.id} className="flex items-center gap-2 border-b border-white/5 last:border-b-0" style={{ padding: "8px 12px" }}>
                <span className="text-text-primary truncate" style={{ fontSize: 13 }}>{sub.title}</span>
                {sub.categories.length > 0 && (
                  <span className="text-text-muted flex-shrink-0" style={{ fontSize: 11 }}>
                    {sub.categories[0].label}
                  </span>
                )}
              </div>
            ))}
          </div>
        </div>
      )}

      <div className="flex justify-end gap-3">
        <button
          type="button"
          onClick={() => setShowAddFeed(false)}
          className="text-text-secondary hover:text-text-primary rounded-xl hover:bg-white/5 transition-colors"
          style={{ padding: "10px 20px", fontSize: 14 }}
        >
          {result ? "Done" : "Cancel"}
        </button>
        {!result && !subs && (
          <button
            onClick={handlePreview}
            disabled={previewing || !token.trim()}
            className="bg-accent text-white rounded-xl hover:bg-accent-hover disabled:opacity-40 font-medium transition-colors"
            style={{ padding: "10px 24px", fontSize: 14 }}
          >
            {previewing ? "Loading..." : "Preview"}
          </button>
        )}
        {subs && !result && (
          <button
            onClick={handleImport}
            disabled={importing}
            className="bg-accent text-white rounded-xl hover:bg-accent-hover disabled:opacity-40 font-medium transition-colors"
            style={{ padding: "10px 24px", fontSize: 14 }}
          >
            {importing ? "Importing..." : `Import ${subs.length} Feeds`}
          </button>
        )}
      </div>
    </div>
  );
}
