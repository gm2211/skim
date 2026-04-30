import { useEffect, useState } from "react";
import { createPortal } from "react-dom";
import { generateCatchupReport, type CatchupReport, type ChatSource } from "../../services/commands";
import { openUrl } from "@tauri-apps/plugin-opener";
import { useUiStore } from "../../stores/uiStore";
import { AIDisclaimer } from "../common/AIDisclaimer";

interface Props {
  onClose: () => void;
  onOpenArticle?: (articleId: string) => void;
}

const CACHE_TTL_MS = 30 * 60 * 1000;
type CacheEntry = { report: CatchupReport; ts: number };
// Module-scope cache keyed by scope. Persists across dialog open/close in the
// same session, expires after 30m.
const catchupCache = new Map<string, CacheEntry>();

export function CatchupDialog({ onClose, onOpenArticle }: Props) {
  const isPhone = useUiStore((s) => s.isPhone);
  // Catch-up over all unread — inbox would filter to priority>=3 and miss
  // whatever the triage hasn't rated yet.
  const [scope, setScope] = useState<"inbox" | "unread">("unread");
  const [report, setReport] = useState<CatchupReport | null>(() => {
    const c = catchupCache.get("unread");
    return c && Date.now() - c.ts < CACHE_TTL_MS ? c.report : null;
  });
  const [loading, setLoading] = useState(false);
  const [elapsed, setElapsed] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [runSeq, setRunSeq] = useState(0);

  // When scope changes (without explicit re-run), surface cached entry if any.
  useEffect(() => {
    const c = catchupCache.get(scope);
    setReport(c && Date.now() - c.ts < CACHE_TTL_MS ? c.report : null);
  }, [scope]);

  useEffect(() => {
    if (runSeq === 0) return;
    let cancelled = false;
    setLoading(true);
    setError(null);
    setReport(null);
    (async () => {
      try {
        const r = await generateCatchupReport(scope);
        if (!cancelled) {
          setReport(r);
          catchupCache.set(scope, { report: r, ts: Date.now() });
        }
      } catch (e) {
        if (!cancelled) setError(String(e instanceof Error ? e.message : e));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [runSeq, scope]);

  useEffect(() => {
    if (!loading) return;
    const start = Date.now();
    const id = setInterval(() => setElapsed(Math.floor((Date.now() - start) / 1000)), 1000);
    return () => clearInterval(id);
  }, [loading]);

  const sourcesById = new Map<string, ChatSource>();
  (report?.sources ?? []).forEach((s) => sourcesById.set(s.id, s));

  const renderItems = (items: CatchupReport["takeaways"] | undefined, emptyMsg: string) => {
    if (!items || items.length === 0) {
      return (
        <p className="text-text-muted" style={{ fontSize: 12 }}>
          {emptyMsg}
        </p>
      );
    }
    return (
      <ol className="flex flex-col gap-3" style={{ listStyle: "none" }}>
        {items.map((it, i) => (
          <li key={i}>
            <div className="flex items-start gap-2">
              <span
                className="text-text-muted tabular-nums flex-shrink-0"
                style={{ fontSize: 12, fontWeight: 600, marginTop: 2 }}
              >
                {i + 1}.
              </span>
              <div className="flex-1">
                {(() => {
                  const firstId = it.article_ids[0];
                  const openFirst = () => {
                    if (!firstId) return;
                    if (onOpenArticle) {
                      onOpenArticle(firstId);
                      onClose();
                    } else {
                      const s = sourcesById.get(firstId);
                      if (s?.url) openUrl(s.url);
                    }
                  };
                  return (
                    <p
                      onClick={firstId ? openFirst : undefined}
                      className={`text-text-primary ${firstId ? "cursor-pointer hover:text-accent transition-colors" : ""}`}
                      style={{ fontSize: 13, lineHeight: 1.6 }}
                    >
                      {it.text}
                    </p>
                  );
                })()}
                {it.article_ids.length > 0 && (
                  <div className="flex flex-wrap gap-1" style={{ marginTop: 4 }}>
                    {it.article_ids.map((id) => {
                      const s = sourcesById.get(id);
                      if (!s) return null;
                      return (
                        <button
                          key={id}
                          onClick={(e) => {
                            e.stopPropagation();
                            if (onOpenArticle) {
                              onOpenArticle(id);
                              onClose();
                            } else if (s.url) {
                              openUrl(s.url);
                            }
                          }}
                          className="rounded-full bg-accent/10 text-accent hover:bg-accent/20 transition-colors"
                          style={{ padding: "2px 8px", fontSize: 11 }}
                          title={s.title}
                        >
                          {s.feed_title}
                        </button>
                      );
                    })}
                  </div>
                )}
              </div>
            </div>
          </li>
        ))}
      </ol>
    );
  };

  return createPortal(
    <div
      className={`fixed inset-0 bg-black/60 backdrop-blur-sm z-50 ${isPhone ? "" : "flex items-center justify-center"}`}
      onClick={onClose}
    >
      <div
        className={`${isPhone ? "fixed inset-0 overflow-hidden" : "border border-white/10 rounded-2xl shadow-2xl"} flex flex-col`}
        style={{
          background: "rgba(22, 27, 34, 0.98)",
          width: isPhone ? undefined : "min(760px, 92vw)",
          height: isPhone ? undefined : undefined,
          maxHeight: isPhone ? undefined : "90vh",
          margin: isPhone ? 0 : "0 20px",
          paddingTop: isPhone ? "max(env(safe-area-inset-top), 50px)" : 0,
          paddingBottom: isPhone ? "max(env(safe-area-inset-bottom), 12px)" : 0,
        }}
        onClick={(e) => e.stopPropagation()}
      >
        <div
          className="flex items-center gap-2 border-b border-white/5 flex-nowrap"
          style={{ padding: "12px 16px" }}
        >
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="text-accent flex-shrink-0">
            <path d="M13 2L3 14h9l-1 8 10-12h-9z" />
          </svg>
          <h3 className="text-text-primary flex-shrink-0" style={{ fontSize: 15, fontWeight: 600, whiteSpace: "nowrap" }}>
            Catch-up
          </h3>
          <select
            value={scope}
            onChange={(e) => setScope(e.target.value as "inbox" | "unread")}
            disabled={loading}
            className="border border-white/10 rounded-lg text-text-primary flex-1 min-w-0"
            style={{ background: "rgba(255,255,255,0.05)", padding: "5px 10px", fontSize: 12, width: 0, maxWidth: 200 }}
          >
            <option value="inbox">Inbox</option>
            <option value="unread">Unread</option>
          </select>
          <button
            onClick={() => setRunSeq((n) => n + 1)}
            disabled={loading}
            className="bg-accent text-white rounded-lg hover:bg-accent-hover disabled:opacity-40 transition-colors font-medium flex-shrink-0 whitespace-nowrap"
            style={{ padding: "5px 12px", fontSize: 12 }}
          >
            {report ? "⟳" : loading ? "…" : "▶"} {report ? "Re-run" : loading ? "" : "Run"}
          </button>
          <button
            onClick={onClose}
            className="text-text-muted hover:text-text-primary transition-colors flex-shrink-0"
            title="Close"
          >
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M18 6L6 18M6 6l12 12" />
            </svg>
          </button>
        </div>

        <div className="flex-1 overflow-y-auto overflow-x-hidden min-w-0" style={{ padding: "18px 20px" }}>
          {!report && !loading && !error && (
            <p className="text-text-muted text-center" style={{ padding: "40px 0", fontSize: 13 }}>
              Generates 10 key takeaways + notable mentions with clickable sources. Pick a scope and click Run.
            </p>
          )}

          {loading && (
            <div className="text-center" style={{ padding: "40px 0" }}>
              <div className="text-text-muted" style={{ fontSize: 13 }}>
                Reading your feed… <span className="tabular-nums">{elapsed}s</span>
              </div>
            </div>
          )}

          {error && (
            <p className="text-danger" style={{ fontSize: 12 }}>
              {error}
            </p>
          )}

          {report && (
            <>
              <div style={{ marginBottom: 24 }}>
                <h4
                  className="text-text-primary"
                  style={{ fontSize: 13, fontWeight: 600, marginBottom: 10, textTransform: "uppercase", letterSpacing: 0.5 }}
                >
                  Top Takeaways
                </h4>
                {renderItems(report.takeaways, "No takeaways generated.")}
              </div>
              <div>
                <h4
                  className="text-text-primary"
                  style={{ fontSize: 13, fontWeight: 600, marginBottom: 10, textTransform: "uppercase", letterSpacing: 0.5 }}
                >
                  Notable Mentions
                </h4>
                {renderItems(report.notable_mentions, "No notable mentions generated.")}
              </div>
              <div style={{ marginTop: 20 }}>
                <AIDisclaimer />
              </div>
            </>
          )}
        </div>
      </div>
    </div>,
    document.body
  );
}
