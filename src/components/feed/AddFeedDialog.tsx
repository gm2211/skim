import { useRef, useState } from "react";
import { useAddFeed } from "../../hooks/useFeeds";
import { useUiStore } from "../../stores/uiStore";
import { previewOpml, importOpml } from "../../services/commands";
import type { FeedlyImportResult } from "../../services/types";
import { useQueryClient } from "@tanstack/react-query";
import { openUrl } from "@tauri-apps/plugin-opener";

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
  const [entries, setEntries] = useState<OpmlEntry[] | null>(null);
  const [filename, setFilename] = useState<string | null>(null);
  const [importing, setImporting] = useState(false);
  const [result, setResult] = useState<FeedlyImportResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [xml, setXml] = useState<string | null>(null);
  const [dragActive, setDragActive] = useState(false);
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const setShowAddFeed = useUiStore((s) => s.setShowAddFeed);
  const qc = useQueryClient();

  const handleOpenFeedly = async () => {
    try {
      await openUrl(FEEDLY_OPML_URL);
    } catch (e) {
      setError(String(e instanceof Error ? e.message : e));
    }
  };

  const ingestFile = async (file: File) => {
    setError(null);
    setResult(null);
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
    setError(null);
    try {
      const res = await importOpml(xml);
      setResult(res);
      qc.invalidateQueries({ queryKey: ["feeds"] });
      qc.invalidateQueries({ queryKey: ["articles"] });
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
            Feedly's API is paid. Use their OPML export instead:
          </p>

          <Step number={1} title="Download your subscriptions from Feedly">
            <button
              onClick={handleOpenFeedly}
              className="bg-white/10 text-text-primary rounded-lg hover:bg-white/15 transition-colors inline-flex items-center gap-1.5"
              style={{ padding: "8px 14px", fontSize: 13 }}
            >
              <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6M15 3h6v6M10 14L21 3" />
              </svg>
              Open feedly.com/i/opml
            </button>
            <p className="text-text-muted" style={{ fontSize: 11, marginTop: 6, lineHeight: 1.5 }}>
              Auto-downloads an <code>.opml</code> file if you're already signed in.
              <br />
              <strong>Not signed in?</strong> Feedly will redirect you to log in first — once
              that's done, click the button again to grab the file.
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
          Imported {result.imported} feed{result.imported !== 1 ? "s" : ""}.
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
          onClick={() => setShowAddFeed(false)}
          className="text-text-secondary hover:text-text-primary rounded-xl hover:bg-white/5 transition-colors"
          style={{ padding: "10px 20px", fontSize: 14 }}
        >
          {result ? "Done" : "Cancel"}
        </button>
        {entries && !result && (
          <button
            onClick={handleImport}
            disabled={importing || newCount === 0}
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
