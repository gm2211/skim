import { useEffect, useRef, useState } from "react";
import { useAddFeed } from "../../hooks/useFeeds";
import { useUiStore } from "../../stores/uiStore";
import {
  feedlyOauthAvailable,
  feedlyOauthLogin,
  getFeedlyStatus,
  importFeedlyStored,
  importOpml,
  previewOpml,
  refreshAllFeeds,
  triageArticles,
} from "../../services/commands";
import type { FeedlyConnectionStatus, FeedlyImportResult } from "../../services/types";
import { useQueryClient } from "@tanstack/react-query";
import { openUrl } from "@tauri-apps/plugin-opener";
import { useSwipeToDismiss } from "../../hooks/useSwipeToDismiss";

const FEEDLY_OPML_URL = "https://feedly.com/i/opml";

type OpmlEntry = { title: string; url: string; category: string | null; already_exists: boolean };

function Step({ number, title, children }: { number: number; title: string; children: React.ReactNode }) {
  return (
    <div className="flex gap-3" style={{ marginBottom: 14 }}>
      <div
        className="flex-shrink-0 rounded-full bg-accent/15 text-accent flex items-center justify-center"
        style={{ width: 22, height: 22, fontSize: 12, fontWeight: 600, marginTop: 1 }}
      >
        {number}
      </div>
      <div className="flex-1">
        <p className="text-text-primary" style={{ fontSize: 13, fontWeight: 500, marginBottom: 8 }}>
          {title}
        </p>
        {children}
      </div>
    </div>
  );
}

type Tab = "url" | "feedly";

export function AddFeedDialog() {
  const [tab, setTab] = useState<Tab>("url");
  const setShowAddFeed = useUiStore((s) => s.setShowAddFeed);
  const isPhone = useUiStore((s) => s.isPhone);
  const { swipeToDismissHandlers, swipeToDismissStyle } = useSwipeToDismiss(
    isPhone,
    () => setShowAddFeed(false),
  );

  return (
    <div className="fixed inset-0 bg-black/60 backdrop-blur-sm flex items-center justify-center z-50">
      <div
        className="border border-white/10 rounded-2xl w-full max-w-md mx-4 shadow-2xl overflow-hidden"
        style={{ background: "rgba(22, 27, 34, 0.95)", ...swipeToDismissStyle }}
      >
        <div
          className="flex items-center justify-between"
          style={{ padding: "16px 16px 0", touchAction: isPhone ? "pan-y" : undefined }}
          {...swipeToDismissHandlers}
        >
          <h2 style={{ fontSize: 18, fontWeight: 600 }} className="text-text-primary">Add Feed</h2>
          <button
            onClick={() => setShowAddFeed(false)}
            className="tap-target text-text-muted hover:text-text-primary rounded-lg hover:bg-white/10 transition-colors"
            aria-label="Close"
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
  const [entries, setEntries] = useState<OpmlEntry[] | null>(null);
  const [filename, setFilename] = useState<string | null>(null);
  const [importing, setImporting] = useState(false);
  const [directImporting, setDirectImporting] = useState(false);
  const [connecting, setConnecting] = useState(false);
  const [refreshingArticles, setRefreshingArticles] = useState(false);
  const [loadedArticles, setLoadedArticles] = useState<number | null>(null);
  const [result, setResult] = useState<FeedlyImportResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [xml, setXml] = useState<string | null>(null);
  const [dragActive, setDragActive] = useState(false);
  const [copied, setCopied] = useState(false);
  const [oauthAvailable, setOauthAvailable] = useState(false);
  const [feedlyStatus, setFeedlyStatus] = useState<FeedlyConnectionStatus | null>(null);
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const setShowAddFeed = useUiStore((s) => s.setShowAddFeed);
  const isPhone = useUiStore((s) => s.isPhone);
  const qc = useQueryClient();

  useEffect(() => {
    if (isPhone) return;
    feedlyOauthAvailable().then(setOauthAvailable).catch(() => setOauthAvailable(false));
    getFeedlyStatus().then(setFeedlyStatus).catch(() => setFeedlyStatus(null));
  }, [isPhone]);

  const invalidateFeedViews = async () => {
    await Promise.all([
      qc.invalidateQueries({ queryKey: ["feeds"] }),
      qc.invalidateQueries({ queryKey: ["articles"] }),
      qc.invalidateQueries({ queryKey: ["articleCount"] }),
      qc.invalidateQueries({ queryKey: ["inbox"] }),
      qc.invalidateQueries({ queryKey: ["triageStats"] }),
    ]);
  };

  const handleOpenFeedly = async () => {
    try {
      await openUrl(FEEDLY_OPML_URL);
    } catch (e) {
      setError(String(e instanceof Error ? e.message : e));
    }
  };

  const handleCopyFeedlyUrl = async () => {
    setError(null);
    try {
      await navigator.clipboard.writeText(FEEDLY_OPML_URL);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1800);
    } catch (e) {
      setError(String(e instanceof Error ? e.message : e));
    }
  };

  const handleDirectFeedlyImport = async () => {
    setDirectImporting(true);
    setError(null);
    setResult(null);
    setLoadedArticles(null);
    try {
      if (!feedlyStatus?.connected) {
        setConnecting(true);
        const profile = await feedlyOauthLogin();
        setFeedlyStatus({
          connected: true,
          email: profile.email,
          full_name: profile.full_name,
        });
        setConnecting(false);
      }
      const res = await importFeedlyStored();
      setResult(res);
      await invalidateFeedViews();
    } catch (e) {
      setError(String(e instanceof Error ? e.message : e));
    } finally {
      setDirectImporting(false);
      setConnecting(false);
    }
  };

  const ingestFile = async (file: File) => {
    setError(null);
    setResult(null);
    setLoadedArticles(null);
    setFilename(file.name);
    try {
      const text = await file.text();
      setXml(text);
      const list = await previewOpml(text);
      setEntries(list);
    } catch (err) {
      setError(String(err instanceof Error ? err.message : err));
      setEntries(null);
      setXml(null);
    }
  };

  const handleFileChange = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    await ingestFile(file);
  };

  const handleDrop = async (e: React.DragEvent) => {
    e.preventDefault();
    e.stopPropagation();
    setDragActive(false);
    const file = e.dataTransfer.files?.[0];
    if (!file) return;
    const name = file.name.toLowerCase();
    if (!name.endsWith(".opml") && !name.endsWith(".xml")) {
      setError("Please drop an .opml or .xml file.");
      return;
    }
    await ingestFile(file);
  };

  const handleImport = async () => {
    if (!xml) return;
    setImporting(true);
    setRefreshingArticles(false);
    setLoadedArticles(null);
    setError(null);
    try {
      const res = await importOpml(xml);
      setResult(res);
      await invalidateFeedViews();

      if (res.imported > 0) {
        setRefreshingArticles(true);
        try {
          const inserted = await refreshAllFeeds();
          setLoadedArticles(inserted);
          await triageArticles(false).catch(() => undefined);
          await invalidateFeedViews();
        } catch (refreshErr) {
          setError(
            `Imported ${res.imported} feed${res.imported === 1 ? "" : "s"}, but article loading failed: ${
              refreshErr instanceof Error ? refreshErr.message : String(refreshErr)
            }`,
          );
        } finally {
          setRefreshingArticles(false);
        }
      }
    } catch (err) {
      setError(String(err instanceof Error ? err.message : err));
    } finally {
      setImporting(false);
    }
  };

  const newCount = entries ? entries.filter((e) => !e.already_exists).length : 0;

  return (
    <div
      style={{ padding: "16px 24px 24px", position: "relative" }}
      onDragOver={(e) => {
        if (entries || result) return;
        if (!e.dataTransfer.types.includes("Files")) return;
        e.preventDefault();
        e.stopPropagation();
        setDragActive(true);
      }}
      onDragLeave={(e) => {
        if (e.currentTarget.contains(e.relatedTarget as Node)) return;
        setDragActive(false);
      }}
      onDrop={handleDrop}
    >
      {dragActive && !entries && !result && (
        <div
          className="absolute inset-0 flex items-center justify-center pointer-events-none rounded-2xl"
          style={{
            background: "rgba(88, 166, 255, 0.08)",
            border: "2px dashed rgba(88, 166, 255, 0.5)",
            zIndex: 5,
            margin: 8,
          }}
        >
          <span className="text-accent" style={{ fontSize: 14, fontWeight: 500 }}>
            Drop .opml file to import
          </span>
        </div>
      )}
      {!entries && !result && (
        <>
          <p className="text-text-muted" style={{ fontSize: 12, marginBottom: 16 }}>
            Import directly when possible, or use Feedly's OPML export.
          </p>

          {oauthAvailable && !isPhone && (
            <div
              className="rounded-xl border border-accent/20"
              style={{ padding: "12px 14px", marginBottom: 16, background: "rgba(88, 166, 255, 0.06)" }}
            >
              <p className="text-text-primary" style={{ fontSize: 13, fontWeight: 500, marginBottom: 6 }}>
                Best option: sign in once and import directly
              </p>
              <p className="text-text-muted" style={{ fontSize: 11, lineHeight: 1.5, marginBottom: 10 }}>
                This avoids the browser login redirect and private-window tab problem entirely.
              </p>
              <button
                onClick={() => void handleDirectFeedlyImport()}
                disabled={directImporting || connecting}
                className="bg-accent text-white rounded-lg hover:bg-accent-hover disabled:opacity-40 transition-colors inline-flex items-center gap-1.5"
                style={{ padding: "8px 14px", fontSize: 13, fontWeight: 500 }}
              >
                <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <path d="M15 3h6v6M10 14L21 3M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6" />
                </svg>
                {directImporting || connecting
                  ? (connecting ? "Waiting for Feedly..." : "Importing...")
                  : feedlyStatus?.connected
                    ? "Import from connected Feedly"
                    : "Sign in and import"}
              </button>
              {feedlyStatus?.connected && (
                <p className="text-text-muted" style={{ fontSize: 11, marginTop: 8 }}>
                  Connected as {feedlyStatus.full_name || feedlyStatus.email || "Feedly account"}.
                </p>
              )}
            </div>
          )}

          <Step number={1} title="Download your subscriptions from Feedly">
            <div className="flex flex-wrap gap-2">
              <button
                onClick={handleOpenFeedly}
                className="bg-white/10 text-text-primary rounded-lg hover:bg-white/15 transition-colors inline-flex items-center gap-1.5"
                style={{ padding: "8px 14px", fontSize: 13 }}
              >
                <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6M15 3h6v6M10 14L21 3" />
                </svg>
                Open Feedly export
              </button>
              <button
                onClick={handleCopyFeedlyUrl}
                className="bg-white/5 text-text-secondary rounded-lg hover:bg-white/10 hover:text-text-primary transition-colors inline-flex items-center gap-1.5"
                style={{ padding: "8px 14px", fontSize: 13 }}
              >
                <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <rect x="9" y="9" width="13" height="13" rx="2" />
                  <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
                </svg>
                {copied ? "Copied" : "Copy export link"}
              </button>
            </div>
            <p className="text-text-muted" style={{ fontSize: 11, marginTop: 6, lineHeight: 1.5 }}>
              Auto-downloads an <code>.opml</code> file if you're already signed in.
              <br />
              <strong>If Feedly asks you to sign in:</strong> sign in, stay in that same tab,
              then paste the copied export link into that tab's address bar. In private windows,
              a new tab may ask you to sign in again.
            </p>
          </Step>

          <Step number={2} title="Drop the .opml file here, or pick it from disk">
            <input
              ref={fileInputRef}
              type="file"
              accept=".opml,.xml,application/xml,text/xml"
              onChange={handleFileChange}
              style={{ display: "none" }}
            />
            <button
              onClick={() => fileInputRef.current?.click()}
              className="bg-white/10 text-text-primary rounded-lg hover:bg-white/15 transition-colors inline-flex items-center gap-1.5"
              style={{ padding: "8px 14px", fontSize: 13 }}
            >
              <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z M14 2v6h6 M12 18v-6 M9 15l3-3 3 3" />
              </svg>
              Choose .opml file
            </button>
            <p className="text-text-muted" style={{ fontSize: 11, marginTop: 6 }}>
              Or drag and drop the file anywhere on this dialog.
            </p>
            {filename && (
              <p className="text-text-muted" style={{ fontSize: 11, marginTop: 6 }}>
                {filename}
              </p>
            )}
          </Step>
        </>
      )}

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
          <div className="flex items-center gap-2">
            {refreshingArticles && (
              <svg className="smooth-spin flex-shrink-0" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M21 12a9 9 0 1 1-6.219-8.56" />
              </svg>
            )}
            <span>
              Imported {result.imported} feed{result.imported !== 1 ? "s" : ""}.
              {refreshingArticles && " Loading articles..."}
              {!refreshingArticles && loadedArticles !== null && ` Loaded ${loadedArticles} new article${loadedArticles === 1 ? "" : "s"}.`}
            </span>
          </div>
          {result.skipped > 0 && ` ${result.skipped} already existed.`}
          {result.errors.length > 0 && ` ${result.errors.length} error(s).`}
        </div>
      )}

      {entries && !result && (
        <div style={{ marginBottom: 12 }}>
          <p className="text-text-secondary" style={{ fontSize: 13, marginBottom: 8 }}>
            {filename ? `${filename}: ` : ""}
            {entries.length} subscription{entries.length !== 1 ? "s" : ""}
            {newCount !== entries.length && ` (${newCount} new, ${entries.length - newCount} already added)`}
          </p>
          <div
            className="border border-white/10 rounded-xl overflow-y-auto"
            style={{ maxHeight: 220, background: "rgba(255,255,255,0.03)" }}
          >
            {entries.map((e) => (
              <div
                key={e.url}
                className="flex items-center gap-2 border-b border-white/5 last:border-b-0"
                style={{ padding: "8px 12px", opacity: e.already_exists ? 0.5 : 1 }}
              >
                <span className="text-text-primary truncate flex-1" style={{ fontSize: 13 }}>
                  {e.title}
                </span>
                {e.category && (
                  <span className="text-text-muted flex-shrink-0" style={{ fontSize: 11 }}>
                    {e.category}
                  </span>
                )}
                {e.already_exists && (
                  <span className="text-text-muted flex-shrink-0" style={{ fontSize: 11 }}>
                    exists
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
          onClick={() => {
            if (!refreshingArticles) setShowAddFeed(false);
          }}
          disabled={refreshingArticles}
          className="text-text-secondary hover:text-text-primary rounded-xl hover:bg-white/5 transition-colors"
          style={{ padding: "10px 20px", fontSize: 14 }}
        >
          {refreshingArticles ? "Loading..." : result ? "Done" : "Cancel"}
        </button>
        {entries && !result && (
          <button
            onClick={handleImport}
            disabled={importing || refreshingArticles || newCount === 0}
            className="bg-accent text-white rounded-xl hover:bg-accent-hover disabled:opacity-40 font-medium transition-colors"
            style={{ padding: "10px 24px", fontSize: 14 }}
          >
            {importing ? "Importing..." : newCount === 0 ? "Nothing new" : `Import ${newCount} Feeds`}
          </button>
        )}
      </div>
    </div>
  );
}
