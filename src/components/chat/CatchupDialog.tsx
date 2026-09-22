import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import {
  CATCHUP_PROGRESS_EVENT,
  generateCatchupReport,
  type CatchupBrief,
  type CatchupProgress,
  type CatchupReport,
  type CatchupSource,
  type CatchupStory,
} from "../../services/commands";
import { listen } from "@tauri-apps/api/event";
import { openUrl } from "@tauri-apps/plugin-opener";
import { useUiStore } from "../../stores/uiStore";
import { AIDisclaimer } from "../common/AIDisclaimer";
import { useLockBodyScroll } from "../../hooks/useLockBodyScroll";
import { useVisualViewportSync } from "../../hooks/useVisualViewport";
import { useSwipeToDismiss } from "../../hooks/useSwipeToDismiss";
import { useDialogFocus } from "../../hooks/useDialogFocus";
import { useSettings } from "../../hooks/useSettings";
import { AiSetupNotice, isAiSetupError } from "../common/AiSetupNotice";
import { Select } from "../ui/Select";

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
  const [progress, setProgress] = useState<CatchupProgress | null>(null);
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
    setProgress(null);
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

  // The backend pushes the page after every step of its two passes, so stories
  // appear as they are written instead of all at once at the end.
  useEffect(() => {
    let unlisten: (() => void) | null = null;
    let cancelled = false;
    listen<CatchupProgress>(CATCHUP_PROGRESS_EVENT, (event) => {
      setProgress(event.payload);
      const partial = event.payload.report;
      if (partial.stories.length > 0 || partial.briefs.length > 0) setReport(partial);
    }).then((fn) => {
      if (cancelled) fn();
      else unlisten = fn;
    });
    return () => {
      cancelled = true;
      if (unlisten) unlisten();
    };
  }, []);

  const sourcesById = new Map<string, CatchupSource>();
  (report?.sources ?? []).forEach((s) => sourcesById.set(s.id, s));

  const openArticle = (id: string) => {
    if (onOpenArticle) {
      onOpenArticle(id);
      onClose();
      return;
    }
    const source = sourcesById.get(id);
    if (source?.url) openUrl(source.url);
  };

  // The articles a story was built from, printed as a byline under it.
  const renderByline = (articleIds: string[]) => {
    const cited = articleIds.map((id) => sourcesById.get(id)).filter((s): s is CatchupSource => !!s);
    if (cited.length === 0) return null;
    return (
      <div className="flex flex-col" style={{ marginTop: 8, gap: 2 }}>
        {cited.map((source) => (
          <button
            key={source.id}
            onClick={(e) => {
              e.stopPropagation();
              openArticle(source.id);
            }}
            className="text-left min-w-0 group"
            style={{ fontSize: 11.5, lineHeight: 1.5 }}
            title={source.title}
          >
            <span className="text-accent" style={{ fontWeight: 600 }}>
              {source.publication}
            </span>
            <span className="text-text-muted group-hover:text-text-primary transition-colors">
              {"  "}
              {source.title}
            </span>
          </button>
        ))}
      </div>
    );
  };

  // A headline whose lede the second pass has not written yet.
  const renderLedeSkeleton = (lead: boolean) => (
    <div
      className="flex flex-col"
      style={{ marginTop: lead ? 10 : 8, gap: 7 }}
      aria-label="Writing this story"
    >
      <div className="story-skeleton-line" style={{ width: "100%" }} />
      <div className="story-skeleton-line" style={{ width: lead ? "92%" : "84%" }} />
      <div className="story-skeleton-line" style={{ width: lead ? "68%" : "56%" }} />
    </div>
  );

  const renderStory = (story: CatchupStory, index: number) => {
    const lead = index === 0;
    return (
      <article
        key={`${index}-${story.headline}`}
        className="story-rise-in"
        style={{
          borderTop: lead ? undefined : "1px solid rgba(255,255,255,0.06)",
          paddingTop: lead ? 0 : 18,
          marginTop: lead ? 0 : 18,
        }}
      >
        <h4
          onClick={story.article_ids[0] ? () => openArticle(story.article_ids[0]) : undefined}
          className={`text-text-primary ${story.article_ids[0] ? "cursor-pointer hover:text-accent transition-colors" : ""}`}
          style={{
            fontSize: lead ? 23 : 16,
            fontWeight: lead ? 700 : 650,
            lineHeight: lead ? 1.2 : 1.3,
            letterSpacing: lead ? -0.4 : -0.2,
          }}
        >
          {story.headline}
        </h4>
        {story.lede ? (
          <p
            className="text-text-primary"
            style={{
              marginTop: lead ? 10 : 6,
              fontSize: lead ? 14.5 : 13,
              lineHeight: 1.65,
              opacity: 0.86,
            }}
          >
            {story.lede}
          </p>
        ) : (
          renderLedeSkeleton(lead)
        )}
        {renderByline(story.article_ids)}
      </article>
    );
  };

  const renderBrief = (brief: CatchupBrief, index: number) => {
    const firstId = brief.article_ids[0];
    return (
      <li key={`${index}-${brief.text}`} className="story-rise-in flex items-start gap-2">
        <span
          className="text-accent flex-shrink-0"
          style={{ fontSize: 13, lineHeight: 1.6 }}
          aria-hidden="true"
        >
          &#8226;
        </span>
        <div className="min-w-0 flex-1">
          <p
            onClick={firstId ? () => openArticle(firstId) : undefined}
            className={`text-text-primary ${firstId ? "cursor-pointer hover:text-accent transition-colors" : ""}`}
            style={{ fontSize: 13, lineHeight: 1.6, opacity: 0.86 }}
          >
            {brief.text}
          </p>
          {renderByline(brief.article_ids.slice(0, 2))}
        </div>
      </li>
    );
  };

  const sectionHeadingStyle = {
    fontSize: 11,
    fontWeight: 700,
    textTransform: "uppercase" as const,
    letterSpacing: 1.2,
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
          <label className="flex min-w-0 flex-col gap-1">
            <span className="text-text-muted" style={{ fontSize: 12, fontWeight: 600 }}>Include</span>
            <Select
              value={scope}
              onChange={(e) => setScope(e.target.value as "inbox" | "unread")}
              disabled={loading}
            >
              <option value="inbox">Priority inbox</option>
              <option value="unread">All unread articles</option>
            </Select>
          </label>
          <button
            onClick={run}
            disabled={loading || providerUnavailable}
            className="bg-accent text-white rounded-lg hover:bg-accent-hover disabled:opacity-40 transition-colors font-medium flex-shrink-0 whitespace-nowrap"
            style={{ padding: "9px 16px", fontSize: 13, minHeight: 40, marginLeft: "auto" }}
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
                Choose which articles to include, then run a catch-up. Skim reads them and writes you a
                front page: the few stories that actually happened, biggest first.
              </p>
            </div>
          )}

          {loading && !report && (
            <div style={{ padding: "36px 0" }}>
              <div className="flex items-center gap-3">
                <svg
                  className="smooth-spin text-accent"
                  width="15"
                  height="15"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="2"
                  aria-hidden="true"
                >
                  <path d="M21 12a9 9 0 1 1-6.219-8.56" />
                </svg>
                <span className="text-text-primary" style={{ fontSize: 14, fontWeight: 600 }}>
                  {progress?.message ?? "Reading your feed…"}
                </span>
                <span className="text-text-muted tabular-nums" style={{ fontSize: 12 }}>
                  {elapsed}s
                </span>
              </div>
              <div
                className="flex flex-col"
                style={{ marginTop: 26, gap: 22 }}
                aria-hidden="true"
              >
                {[0, 1, 2].map((row) => (
                  <div key={row} className="flex flex-col" style={{ gap: 8 }}>
                    <div
                      className="story-skeleton-line"
                      style={{ height: row === 0 ? 17 : 13, width: row === 0 ? "78%" : "62%" }}
                    />
                    <div className="story-skeleton-line" style={{ width: "100%" }} />
                    <div className="story-skeleton-line" style={{ width: "84%" }} />
                  </div>
                ))}
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
              {loading && (
                <div style={{ marginBottom: 18 }}>
                  <div className="flex items-center gap-2">
                    <span className="text-text-muted" style={{ fontSize: 12 }}>
                      {progress?.message ?? "Writing the page…"}
                    </span>
                    <span className="text-text-muted tabular-nums" style={{ fontSize: 12 }}>
                      {elapsed}s
                    </span>
                  </div>
                  <div
                    className="story-rule-live"
                    style={{ height: 2, borderRadius: 999, marginTop: 8 }}
                  />
                </div>
              )}

              {report.stories.length === 0 && report.briefs.length === 0 && !loading && (
                <p className="text-text-muted" style={{ fontSize: 13, lineHeight: 1.6 }}>
                  Nothing on the page — there was no real news in these articles.
                </p>
              )}

              {report.stories.map((story, index) => renderStory(story, index))}

              {report.briefs.length > 0 && (
                <div
                  style={{
                    marginTop: report.stories.length > 0 ? 28 : 0,
                    borderTop: report.stories.length > 0 ? "1px solid rgba(255,255,255,0.1)" : undefined,
                    paddingTop: report.stories.length > 0 ? 20 : 0,
                  }}
                >
                  <h4 className="text-text-muted" style={sectionHeadingStyle}>
                    Also
                  </h4>
                  <ul className="flex flex-col" style={{ listStyle: "none", marginTop: 12, gap: 12 }}>
                    {report.briefs.map((brief, index) => renderBrief(brief, index))}
                  </ul>
                </div>
              )}
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
