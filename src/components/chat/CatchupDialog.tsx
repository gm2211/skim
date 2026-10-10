import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import {
  CATCHUP_CANCELLED,
  CATCHUP_PROGRESS_EVENT,
  cancelCatchupReport,
  generateCatchupReport,
  type CatchupProgress,
  type CatchupReport,
  type CatchupScope,
  type CatchupSinceHours,
  type CatchupSource,
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
import { ModelPicker } from "../common/ModelPicker";
import { CatchupFrontPage, CatchupGhostPage } from "./CatchupFrontPage";

interface Props {
  onClose: () => void;
  onOpenArticle?: (articleId: string) => void;
}

const CACHE_TTL_MS = 30 * 60 * 1000;
type CacheEntry = { report: CatchupReport; ts: number };
// Module-scope cache keyed by scope + time range. Persists across dialog
// open/close in the same session, expires after 30m.
const catchupCache = new Map<string, CacheEntry>();
const catchupErrors = new Map<string, string>();

/** The one size every control on the masthead's toolbar shares. */
const CONTROL_STYLE = { height: 32, minHeight: 32, fontSize: 12.5, padding: "0 30px 0 10px" } as const;

/** How far back to catch up. `null` is the whole unread backlog. */
export const CATCHUP_RANGES: { value: CatchupSinceHours; label: string }[] = [
  { value: 6, label: "Last 6 hours" },
  { value: 24, label: "Last 24 hours" },
  { value: 72, label: "Last 3 days" },
  { value: 168, label: "Last week" },
  { value: null, label: "Anything unread" },
];

export const catchupCacheKey = (scope: CatchupScope, sinceHours: CatchupSinceHours) =>
  `${scope}:${sinceHours ?? "all"}`;

/**
 * The last scope and range the reader chose, kept outside the component so
 * reopening the dialog does not silently snap back to the defaults. Exported
 * so tests can put it back where it started.
 */
export const catchupSelection: { scope: CatchupScope; sinceHours: CatchupSinceHours } = {
  scope: "unread",
  sinceHours: null,
};

/**
 * One line naming what the run actually read. Without it the two scopes look
 * identical from the outside, which is exactly the complaint that produced it.
 */
export function catchupScopeSummary(
  scope: CatchupScope,
  sinceHours: CatchupSinceHours,
  articleCount: number
): string {
  const articles = `${articleCount} ${articleCount === 1 ? "article" : "articles"}`;
  const label = CATCHUP_RANGES.find((r) => r.value === sinceHours)?.label;
  const window = sinceHours == null || !label ? "" : ` from the ${label.toLowerCase()}`;
  const source = scope === "inbox" ? "your priority inbox" : "everything unread";
  return `Read ${articles} from ${source}${window}.`;
}

export function CatchupDialog({ onClose, onOpenArticle }: Props) {
  const isPhone = useUiStore((s) => s.isPhone);
  const showSettings = useUiStore((s) => s.showSettings);
  const { data: settings } = useSettings();
  useLockBodyScroll(isPhone && !showSettings);
  const dialogRef = useRef<HTMLDivElement>(null);
  useDialogFocus(dialogRef, onClose, !showSettings);
  useVisualViewportSync(dialogRef, isPhone && !showSettings);
  const { swipeToDismissHandlers, swipeToDismissStyle } = useSwipeToDismiss(isPhone, onClose);
  // Defaults to everything unread: the priority scope only holds articles
  // triage has rated 4 or 5, so it is a deliberate narrowing, not a starting
  // point. Both survive closing the dialog.
  const [scope, setScope] = useState<CatchupScope>(catchupSelection.scope);
  const [sinceHours, setSinceHours] = useState<CatchupSinceHours>(catchupSelection.sinceHours);
  const cacheKey = catchupCacheKey(scope, sinceHours);
  const [report, setReport] = useState<CatchupReport | null>(() => {
    const c = catchupCache.get(catchupCacheKey(catchupSelection.scope, catchupSelection.sinceHours));
    return c && Date.now() - c.ts < CACHE_TTL_MS ? c.report : null;
  });
  const [loading, setLoading] = useState(false);
  const [elapsed, setElapsed] = useState(0);
  const [error, setError] = useState<string | null>(
    () => catchupErrors.get(catchupCacheKey(catchupSelection.scope, catchupSelection.sinceHours)) ?? null
  );
  const [progress, setProgress] = useState<CatchupProgress | null>(null);
  // How many stories have their lede in. The page prints those, plus the one
  // being written, so each story lands on its own as soon as it is ready
  // rather than the whole page arriving at the end.
  const [written, setWritten] = useState(Number.POSITIVE_INFINITY);
  // The run currently in flight, so a stale response or a stopped run cannot
  // clobber a newer one — and so an unmount or a scope change mid-run knows
  // what to tell the backend to cancel.
  const activeRun = useRef<string | null>(null);
  const [stopped, setStopped] = useState(false);
  const previousSettings = useRef(settings);

  useEffect(() => {
    if (previousSettings.current === settings) return;
    previousSettings.current = settings;
    for (const [key, message] of catchupErrors) {
      if (isAiSetupError(message)) catchupErrors.delete(key);
    }
    setError((previous) => isAiSetupError(previous) ? null : previous);
  }, [settings]);

  // When either control changes (without an explicit re-run), surface the
  // cached page for that combination if there is one.
  useEffect(() => {
    catchupSelection.scope = scope;
    catchupSelection.sinceHours = sinceHours;
    const c = catchupCache.get(cacheKey);
    setReport(c && Date.now() - c.ts < CACHE_TTL_MS ? c.report : null);
    setWritten(Number.POSITIVE_INFINITY);
    setError(catchupErrors.get(cacheKey) ?? null);
    setStopped(false);
  }, [cacheKey, scope, sinceHours]);

  const run = async () => {
    const runKey = cacheKey;
    const runScope = scope;
    const runSinceHours = sinceHours;
    const id = globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(36).slice(2)}`;
    activeRun.current = id;
    setStopped(false);
    setLoading(true);
    setError(null);
    setProgress(null);
    setWritten(0);
    catchupErrors.delete(runKey);
    setReport(null);
    try {
      const nextReport = await generateCatchupReport(runScope, runSinceHours, id);
      if (activeRun.current !== id) return;
      setReport(nextReport);
      setWritten(Number.POSITIVE_INFINITY);
      catchupCache.set(runKey, { report: nextReport, ts: Date.now() });
    } catch (caught) {
      if (activeRun.current !== id) return;
      const message = String(caught instanceof Error ? caught.message : caught);
      if (message === CATCHUP_CANCELLED) return;
      setError(message);
      catchupErrors.set(runKey, message);
    } finally {
      if (activeRun.current === id) {
        setLoading(false);
        activeRun.current = null;
      }
    }
  };

  const stop = () => {
    const id = activeRun.current;
    activeRun.current = null;
    setLoading(false);
    setProgress(null);
    setStopped(true);
    void cancelCatchupReport(id ?? undefined);
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
      if (event.payload.run_id !== activeRun.current) return;
      setProgress(event.payload);
      setWritten(event.payload.stage === "done" ? Number.POSITIVE_INFINITY : event.payload.completed);
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

  // Closing the dialog (or its parent unmounting) mid-run must not leave
  // backend work running unattended.
  useEffect(() => {
    return () => {
      if (activeRun.current) void cancelCatchupReport(activeRun.current);
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

  const dateline = new Date().toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric", year: "numeric" });

  if (showSettings) return null;

  const providerUnavailable = settings?.ai.provider === "none";
  const setupError = isAiSetupError(error);
  // Before the first run the page itself invites the run, so the toolbar
  // does not need a second button saying the same thing.
  const inviting = !providerUnavailable && !report && !loading && !error;

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
          width: isPhone ? undefined : "min(1040px, 94vw)",
          height: isPhone ? "100dvh" : undefined,
          top: isPhone ? 0 : undefined,
          willChange: isPhone ? "transform, height" : undefined,
          ...swipeToDismissStyle,
          maxHeight: isPhone ? undefined : "92vh",
          margin: isPhone ? 0 : "0 20px",
          paddingTop: isPhone ? "max(var(--sat, 0px), 60px)" : 0,
          paddingBottom: isPhone ? "max(var(--sab, 0px), 12px)" : 0,
        }}
        onClick={(e) => e.stopPropagation()}
      >
        <div
          className="relative border-b border-white/5"
          style={{ padding: isPhone ? "16px 56px 16px 16px" : "14px 76px 14px 28px", touchAction: isPhone ? "pan-y" : undefined }}
          {...swipeToDismissHandlers}
        >
          {/* The nameplate and the run's controls share one row, like a
              masthead over its toolbar; on a narrow window the controls wrap
              under the title. */}
          <div className="flex flex-wrap items-center" style={{ columnGap: 20, rowGap: 10 }}>
            <h3 id="catchup-title" className="catchup-nameplate text-text-primary" style={{ marginRight: "auto" }}>
              Quick Catch-up
            </h3>
            <div className="flex flex-wrap items-center" style={{ gap: 8 }}>
              <label className="catchup-control">
                <span className="catchup-control-label">Model</span>
                <ModelPicker surface="catchup" disabled={loading} controlStyle={CONTROL_STYLE} />
              </label>
              <label className="catchup-control">
                <span className="catchup-control-label">Include</span>
                <Select
                  aria-label="Include"
                  value={scope}
                  onChange={(e) => {
                    if (loading) stop();
                    setScope(e.target.value as CatchupScope);
                  }}
                  style={CONTROL_STYLE}
                >
                  <option value="inbox">Priority inbox</option>
                  <option value="unread">All unread articles</option>
                </Select>
              </label>
              <label className="catchup-control">
                <span className="catchup-control-label">Going back</span>
                <Select
                  aria-label="Going back"
                  value={sinceHours === null ? "all" : String(sinceHours)}
                  onChange={(e) => {
                    if (loading) stop();
                    setSinceHours(e.target.value === "all" ? null : Number(e.target.value));
                  }}
                  style={CONTROL_STYLE}
                >
                  {CATCHUP_RANGES.map((range) => (
                    <option
                      key={range.label}
                      value={range.value === null ? "all" : String(range.value)}
                    >
                      {range.label}
                    </option>
                  ))}
                </Select>
              </label>
              {loading ? (
                <button
                  onClick={stop}
                  className="border border-white/10 hover:bg-white/10 text-text-primary rounded-lg transition-colors font-medium flex-shrink-0 whitespace-nowrap"
                  style={{ ...CONTROL_STYLE, padding: "0 14px", fontSize: 13 }}
                  aria-label="Stop catch-up"
                >
                  Stop
                </button>
              ) : inviting ? null : (
                <button
                  onClick={run}
                  disabled={providerUnavailable}
                  className="bg-accent text-white rounded-lg hover:bg-accent-hover disabled:opacity-40 transition-colors font-medium flex-shrink-0 whitespace-nowrap"
                  style={{ ...CONTROL_STYLE, padding: "0 14px", fontSize: 13 }}
                >
                  {report ? "Run again" : "Run catch-up"}
                </button>
              )}
            </div>
          </div>
          <button
            onClick={onClose}
            className="tap-target absolute text-text-muted hover:text-text-primary transition-colors rounded-lg hover:bg-white/10"
            style={{ right: isPhone ? 12 : 16, top: isPhone ? 12 : "50%", transform: isPhone ? undefined : "translateY(-50%)" }}
            title="Close"
            aria-label="Close"
          >
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true">
              <path d="M18 6L6 18M6 6l12 12" />
            </svg>
          </button>
        </div>

        <div className="flex-1 overflow-y-auto overflow-x-hidden min-w-0" style={{ padding: isPhone ? "20px 16px" : "22px 28px 28px", minHeight: isPhone ? 0 : 260 }}>
          {providerUnavailable && <AiSetupNotice />}

          {!providerUnavailable && !report && !loading && !error && (
            <CatchupGhostPage dateline={dateline}>
              <div className="catchup-invite">
                <h4 className="catchup-headline text-text-primary" style={{ fontSize: 22, fontWeight: 700, letterSpacing: -0.2 }}>
                  {stopped ? "Catch-up stopped." : "Your front page is blank."}
                </h4>
                <p className="text-text-muted" style={{ marginTop: 8, fontSize: 13, lineHeight: 1.6 }}>
                  {stopped
                    ? "Run again to write the page, or change what it should cover first."
                    : "Choose what to include and how far back to go. Skim reads the articles and writes you a front page: the few stories that actually happened, biggest first."}
                </p>
                <button
                  onClick={run}
                  className="bg-accent text-white rounded-lg hover:bg-accent-hover transition-colors font-medium"
                  style={{ marginTop: 16, height: 36, padding: "0 18px", fontSize: 13 }}
                >
                  {stopped ? "Run again" : "Run catch-up"}
                </button>
              </div>
            </CatchupGhostPage>
          )}

          {loading && !report && (
            <CatchupGhostPage dateline={dateline} status={{ message: progress?.message ?? "Reading your feed…", elapsed }} />
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
              {!loading && stopped && (
                <p className="text-text-muted" style={{ fontSize: 12, marginBottom: 18 }}>
                  Stopped. Run again to finish the page.
                </p>
              )}

              {report.stories.length === 0 && report.briefs.length === 0 && !loading && !stopped && (
                <p className="text-text-muted" style={{ fontSize: 13, lineHeight: 1.6 }}>
                  {report.article_count === 0
                    ? scope === "inbox"
                      ? "Nothing in your priority inbox for that time range. Triage rates most articles 2 or 3; only 4s and 5s reach this scope."
                      : "Nothing unread in that time range."
                    : "Nothing on the page — there was no real news in these articles."}
                </p>
              )}

              <CatchupFrontPage
                report={report}
                dateline={dateline}
                scopeSummary={!loading && !stopped && report.article_count > 0 ? catchupScopeSummary(scope, sinceHours, report.article_count) : null}
                status={{ message: progress?.message ?? "Writing the page…", elapsed }}
                loading={loading}
                written={written}
                onOpenArticle={openArticle}
              />
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
