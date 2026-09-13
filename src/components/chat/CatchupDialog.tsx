import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { generateCatchupReport, type CatchupReport, type ChatSource } from "../../services/commands";
import { openUrl } from "@tauri-apps/plugin-opener";
import { useUiStore } from "../../stores/uiStore";
import { AIDisclaimer } from "../common/AIDisclaimer";
import { useLockBodyScroll } from "../../hooks/useLockBodyScroll";
import { useVisualViewportSync } from "../../hooks/useVisualViewport";
import { useSwipeToDismiss } from "../../hooks/useSwipeToDismiss";
import { useDialogFocus } from "../../hooks/useDialogFocus";
import { useSettings } from "../../hooks/useSettings";
import { AiSetupNotice, isAiSetupError } from "../common/AiSetupNotice";

interface Props {
  onClose: () => void;
  onOpenArticle?: (articleId: string) => void;
}

const CACHE_TTL_MS = 30 * 60 * 1000;
type CacheEntry = { report: CatchupReport; ts: number };
// Module-scope cache keyed by scope. Persists across dialog open/close in the
// same session, expires after 30m.
const catchupCache = new Map<string, CacheEntry>();
const catchupErrors = new Map<string, string>();

export function CatchupDialog({ onClose, onOpenArticle }: Props) {
  const isPhone = useUiStore((s) => s.isPhone);
  const showSettings = useUiStore((s) => s.showSettings);
  const { data: settings } = useSettings();
  useLockBodyScroll(isPhone && !showSettings);
  const dialogRef = useRef<HTMLDivElement>(null);
  useDialogFocus(dialogRef, onClose, !showSettings);
  useVisualViewportSync(dialogRef, isPhone && !showSettings);
  const { swipeToDismissHandlers, swipeToDismissStyle } = useSwipeToDismiss(isPhone, onClose);
  // Catch-up over all unread — inbox would filter to priority>=3 and miss
  // whatever the triage hasn't rated yet.
  const [scope, setScope] = useState<"inbox" | "unread">("unread");
  const [report, setReport] = useState<CatchupReport | null>(() => {
    const c = catchupCache.get("unread");
    return c && Date.now() - c.ts < CACHE_TTL_MS ? c.report : null;
  });
  const [loading, setLoading] = useState(false);
  const [elapsed, setElapsed] = useState(0);
  const [error, setError] = useState<string | null>(() => catchupErrors.get("unread") ?? null);
  const previousSettings = useRef(settings);

  useEffect(() => {
    if (previousSettings.current === settings) return;
    previousSettings.current = settings;
    for (const [key, message] of catchupErrors) {
      if (isAiSetupError(message)) catchupErrors.delete(key);
    }
    setError((previous) => isAiSetupError(previous) ? null : previous);
  }, [settings]);

  // When scope changes (without explicit re-run), surface cached entry if any.
  useEffect(() => {
    const c = catchupCache.get(scope);
    setReport(c && Date.now() - c.ts < CACHE_TTL_MS ? c.report : null);
    setError(catchupErrors.get(scope) ?? null);
  }, [scope]);

  const run = async () => {
    const runScope = scope;
    setLoading(true);
    setError(null);
    catchupErrors.delete(runScope);
    setReport(null);
    try {
      const nextReport = await generateCatchupReport(runScope);
      setReport(nextReport);
      catchupCache.set(runScope, { report: nextReport, ts: Date.now() });
    } catch (caught) {
      const message = String(caught instanceof Error ? caught.message : caught);
      setError(message);
      catchupErrors.set(runScope, message);
    } finally {
      setLoading(false);
    }
  };

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

  if (showSettings) return null;

  const providerUnavailable = settings?.ai.provider === "none";
  const setupError = isAiSetupError(error);

  return createPortal(
    <div
      className={`fixed inset-0 bg-black/60 backdrop-blur-sm z-50 dialog-fade-in ${isPhone ? "" : "flex items-center justify-center"}`}
      onClick={onClose}
    >
      <div
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby="catchup-title"
        className={`${isPhone ? "fixed left-0 right-0 overflow-hidden" : "border border-white/10 rounded-2xl shadow-2xl"} flex flex-col`}
        style={{
          background: "rgba(22, 27, 34, 0.98)",
          width: isPhone ? undefined : "min(760px, 92vw)",
          height: isPhone ? "100dvh" : undefined,
          top: isPhone ? 0 : undefined,
          willChange: isPhone ? "transform, height" : undefined,
          ...swipeToDismissStyle,
          maxHeight: isPhone ? undefined : "90vh",
          margin: isPhone ? 0 : "0 20px",
          paddingTop: isPhone ? "max(var(--sat, 0px), 60px)" : 0,
          paddingBottom: isPhone ? "max(var(--sab, 0px), 12px)" : 0,
        }}
        onClick={(e) => e.stopPropagation()}
      >
        <div
          className="relative border-b border-white/5"
          style={{ padding: isPhone ? "16px 56px 16px 16px" : "20px 64px 20px 24px", touchAction: isPhone ? "pan-y" : undefined }}
          {...swipeToDismissHandlers}
        >
          <h3 id="catchup-title" className="text-text-primary" style={{ fontSize: 20, lineHeight: 1.3, fontWeight: 650 }}>
            Quick Catch-up
          </h3>
          <p className="text-text-muted" style={{ marginTop: 4, fontSize: 13, lineHeight: 1.5 }}>
            Turn your latest articles into a concise briefing.
          </p>
          <button
            onClick={onClose}
            className="tap-target absolute text-text-muted hover:text-text-primary transition-colors rounded-lg hover:bg-white/10"
            style={{ right: isPhone ? 12 : 16, top: isPhone ? 12 : 16 }}
            title="Close"
            aria-label="Close"
          >
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true">
              <path d="M18 6L6 18M6 6l12 12" />
            </svg>
          </button>
        </div>

        <div className="flex items-end gap-3 border-b border-white/5" style={{ padding: isPhone ? "12px 16px" : "12px 24px" }}>
          <label className="flex min-w-0 flex-1 flex-col gap-1">
            <span className="text-text-muted" style={{ fontSize: 12, fontWeight: 600 }}>Include</span>
          <select
            value={scope}
            onChange={(e) => setScope(e.target.value as "inbox" | "unread")}
            disabled={loading}
            className="border border-white/10 rounded-lg text-text-primary min-w-0"
            style={{ background: "rgba(255,255,255,0.05)", padding: "9px 12px", fontSize: 13, minHeight: 40 }}
          >
            <option value="inbox">Priority inbox</option>
            <option value="unread">All unread articles</option>
          </select>
          </label>
          <button
            onClick={run}
            disabled={loading || providerUnavailable}
            className="bg-accent text-white rounded-lg hover:bg-accent-hover disabled:opacity-40 transition-colors font-medium flex-shrink-0 whitespace-nowrap"
            style={{ padding: "9px 16px", fontSize: 13, minHeight: 40 }}
          >
            {loading ? "Working…" : report ? "Run again" : "Run catch-up"}
          </button>
        </div>

        <div className="flex-1 overflow-y-auto overflow-x-hidden min-w-0" style={{ padding: isPhone ? "20px 16px" : "24px", minHeight: isPhone ? 0 : 260 }}>
          {providerUnavailable && <AiSetupNotice />}

          {!providerUnavailable && !report && !loading && !error && (
            <div style={{ padding: "24px 0" }}>
              <h4 className="text-text-primary" style={{ fontSize: 15, fontWeight: 600 }}>Ready when you are</h4>
              <p className="text-text-muted" style={{ marginTop: 6, fontSize: 13, lineHeight: 1.6 }}>
                Choose which articles to include, then run a catch-up for key takeaways and notable mentions.
              </p>
            </div>
          )}

          {loading && (
            <div className="text-center" style={{ padding: "40px 0" }}>
              <div className="text-text-muted" style={{ fontSize: 13 }}>
                Reading your feed… <span className="tabular-nums">{elapsed}s</span>
              </div>
            </div>
          )}

          {error && setupError && <AiSetupNotice error={error} />}

          {error && !setupError && (
            <div role="alert" className="rounded-xl border border-danger/30 bg-danger/10" style={{ padding: 16 }}>
              <p className="text-danger" style={{ fontSize: 13 }}>{error}</p>
              <button onClick={run} className="text-text-primary border border-white/10 rounded-lg hover:bg-white/10" style={{ marginTop: 12, padding: "8px 12px", minHeight: 40, fontSize: 13 }}>
                Try again
              </button>
            </div>
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
            </>
          )}
        </div>

        <div className="border-t border-white/5 flex-shrink-0" style={{ padding: "8px 20px" }}>
          <AIDisclaimer />
        </div>
      </div>
    </div>,
    document.body
  );
}
