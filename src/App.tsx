import { Sidebar } from "./components/layout/Sidebar";
import { ArticleList } from "./components/layout/ArticleList";
import { ArticleDetail } from "./components/layout/ArticleDetail";
import { AddFeedDialog } from "./components/feed/AddFeedDialog";
import { SettingsDialog } from "./components/settings/SettingsDialog";
import { useUiStore } from "./stores/uiStore";
import { useEffect, useRef, useState } from "react";
import { triageArticles, refreshAllFeeds, importOpml } from "./services/commands";
import { useQueryClient } from "@tanstack/react-query";
import { AIBootDisclaimer } from "./components/common/AIBootDisclaimer";

type OpmlImportStatus = {
  phase: "importing" | "refreshing" | "done" | "error";
  message: string;
};

type PhonePaneTransition = "none" | "slide" | "settle";

const PHONE_PANE_INTENT_PX = 8;
const PHONE_PANE_VERTICAL_CANCEL_PX = 36;
const PHONE_PANE_COMMIT_MAX_PX = 92;
const PHONE_PANE_COMMIT_RATIO = 0.24;
const PHONE_PANE_FAST_PX_PER_MS = 0.42;
const PHONE_PANE_SLIDE_MS = 390;
const PHONE_PANE_SETTLE_MS = 280;
const PHONE_SLIDE_EASING = "cubic-bezier(0.16, 1, 0.3, 1)";
const PHONE_SETTLE_EASING = "cubic-bezier(0.2, 0.9, 0.2, 1)";
const ACTIVE_FEED_TOAST_MAX_MS = 35000;

function App() {
  const { showAddFeed, showSettings, selectedArticleId, listCollapsed, isPhone, phonePane } = useUiStore();
  const qc = useQueryClient();
  const [showBootDisclaimer, setShowBootDisclaimer] = useState(true);
  const [opmlImportStatus, setOpmlImportStatus] = useState<OpmlImportStatus | null>(null);
  const [phonePaneDragOffset, setPhonePaneDragOffset] = useState(0);
  const [phonePaneTransition, setPhonePaneTransition] = useState<PhonePaneTransition>("slide");
  const [suppressNextPhonePaneTransition, setSuppressNextPhonePaneTransition] = useState(false);
  const lastRefreshRef = useRef<number>(Date.now());

  // Auto-load feed articles on startup. OPML import intentionally registers
  // feeds quickly, then this normal refresh path fills articles.
  useEffect(() => {
    let cancelled = false;
    let statusTimer: number | null = window.setTimeout(() => {
      if (!cancelled) {
        setOpmlImportStatus({ phase: "refreshing", message: "Loading feed articles..." });
      }
    }, 900);

    const invalidate = async () => {
      await Promise.all([
        qc.invalidateQueries({ queryKey: ["feeds"] }),
        qc.invalidateQueries({ queryKey: ["articles"] }),
        qc.invalidateQueries({ queryKey: ["articleCount"] }),
        qc.invalidateQueries({ queryKey: ["inbox"] }),
        qc.invalidateQueries({ queryKey: ["triageStats"] }),
      ]);
    };

    refreshAllFeeds()
      .then(async (inserted) => {
        lastRefreshRef.current = Date.now();
        await invalidate();
        await triageArticles(false).catch(() => undefined);
        await invalidate();
        if (!cancelled && inserted > 0) {
          setOpmlImportStatus({
            phase: "done",
            message: `Loaded ${inserted} new article${inserted === 1 ? "" : "s"}.`,
          });
          window.setTimeout(() => {
            if (!cancelled) setOpmlImportStatus(null);
          }, 2200);
        } else if (!cancelled) {
          setOpmlImportStatus(null);
        }
      })
      .catch((err) => {
        if (!cancelled) {
          setOpmlImportStatus({
            phase: "error",
            message: `Couldn't load feed articles: ${err instanceof Error ? err.message : String(err)}`,
          });
        }
      })
      .finally(() => {
        if (statusTimer !== null) {
          window.clearTimeout(statusTimer);
          statusTimer = null;
        }
      });

    return () => {
      cancelled = true;
      if (statusTimer !== null) window.clearTimeout(statusTimer);
    };
  }, [qc]);

  // Feed refreshes can keep running after the UI no longer needs a blocking
  // status toast. Never let an active feed-loading toast pin itself forever.
  useEffect(() => {
    if (
      opmlImportStatus?.phase !== "importing" &&
      opmlImportStatus?.phase !== "refreshing"
    ) {
      return;
    }

    const phase = opmlImportStatus.phase;
    const message = opmlImportStatus.message;
    const timer = window.setTimeout(() => {
      setOpmlImportStatus((current) => {
        if (current?.phase === phase && current.message === message) {
          return null;
        }
        return current;
      });
    }, ACTIVE_FEED_TOAST_MAX_MS);

    return () => window.clearTimeout(timer);
  }, [opmlImportStatus?.phase, opmlImportStatus?.message]);

  // Auto-refresh on window focus if last refresh was > 1 hour ago.
  useEffect(() => {
    const STALE_MS = 60 * 60 * 1000;
    const onFocus = () => {
      if (Date.now() - lastRefreshRef.current < STALE_MS) return;
      lastRefreshRef.current = Date.now();
      refreshAllFeeds()
        .then(() => {
          qc.invalidateQueries({ queryKey: ["feeds"] });
          qc.invalidateQueries({ queryKey: ["articles"] });
          qc.invalidateQueries({ queryKey: ["articleCount"] });
          return triageArticles(false);
        })
        .then(() => {
          qc.invalidateQueries({ queryKey: ["inbox"] });
          qc.invalidateQueries({ queryKey: ["triageStats"] });
        })
        .catch(() => {});
    };
    window.addEventListener("focus", onFocus);
    return () => window.removeEventListener("focus", onFocus);
  }, [qc]);

  // Responsive auto-collapse
  useEffect(() => {
    const apply = () => {
      const width = document.documentElement.clientWidth;
      useUiStore.getState().applyResponsiveLayout(width);
    };
    apply();
    const observer = new ResizeObserver(apply);
    observer.observe(document.documentElement);
    return () => observer.disconnect();
  }, []);

  // OPML drag-drop import (iPad split-view from Files, desktop drop).
  // When the AddFeedDialog is open, defer to its own drop zone so the user
  // gets the preview-then-import flow instead of a silent background import.
  useEffect(() => {
    let clearStatusTimer: number | null = null;
    const invalidateFeedViews = async () => {
      await Promise.all([
        qc.invalidateQueries({ queryKey: ["feeds"] }),
        qc.invalidateQueries({ queryKey: ["articles"] }),
        qc.invalidateQueries({ queryKey: ["articleCount"] }),
        qc.invalidateQueries({ queryKey: ["inbox"] }),
        qc.invalidateQueries({ queryKey: ["triageStats"] }),
      ]);
    };
    const clearSoon = () => {
      if (clearStatusTimer !== null) window.clearTimeout(clearStatusTimer);
      clearStatusTimer = window.setTimeout(() => {
        setOpmlImportStatus(null);
        clearStatusTimer = null;
      }, 2600);
    };
    const onDragOver = (e: DragEvent) => {
      if (e.dataTransfer?.types.includes("Files")) e.preventDefault();
    };
    const onDrop = async (e: DragEvent) => {
      if (useUiStore.getState().showAddFeed) return;
      const files = e.dataTransfer?.files;
      if (!files || files.length === 0) return;
      e.preventDefault();
      for (const file of Array.from(files)) {
        const name = file.name.toLowerCase();
        if (!name.endsWith(".opml") && !name.endsWith(".xml")) continue;
        try {
          setOpmlImportStatus({ phase: "importing", message: `Importing ${file.name}...` });
          const xml = await file.text();
          const res = await importOpml(xml);
          await invalidateFeedViews();
          if (res.imported > 0) {
            setOpmlImportStatus({ phase: "refreshing", message: `Imported ${res.imported} feed${res.imported === 1 ? "" : "s"}. Loading articles...` });
            const inserted = await refreshAllFeeds();
            lastRefreshRef.current = Date.now();
            await triageArticles(false).catch(() => undefined);
            await invalidateFeedViews();
            setOpmlImportStatus({
              phase: "done",
              message: `Loaded ${inserted} new article${inserted === 1 ? "" : "s"} from ${res.imported} feed${res.imported === 1 ? "" : "s"}.`,
            });
          } else {
            setOpmlImportStatus({
              phase: "done",
              message: res.skipped > 0 ? "Those feeds were already imported." : "No new feeds found in that OPML file.",
            });
          }
          clearSoon();
        } catch (err) {
          console.error("OPML drop import failed", err);
          setOpmlImportStatus({
            phase: "error",
            message: err instanceof Error ? err.message : String(err),
          });
          clearSoon();
        }
      }
    };
    window.addEventListener("dragover", onDragOver);
    window.addEventListener("drop", onDrop);
    return () => {
      if (clearStatusTimer !== null) window.clearTimeout(clearStatusTimer);
      window.removeEventListener("dragover", onDragOver);
      window.removeEventListener("drop", onDrop);
    };
  }, [qc]);

  // Phone-mode horizontal gestures are pane navigation, not page scrolling.
  // Article detail owns its Reader/Web/back gestures; the shell handles only
  // sidebar/list transitions so list item swipe actions still work.
  useEffect(() => {
    if (!isPhone) return;
    let startX = 0;
    let startY = 0;
    let lastX = 0;
    let lastAt = 0;
    let velocityX = 0;
    let startPane = useUiStore.getState().phonePane;
    let allowsHorizontalPaneGesture = false;
    let active = false;
    let intent: "pending" | "horizontal" | "vertical" = "pending";
    let targetPane: "sidebar" | "list" | null = null;
    const EDGE_PX = 64;
    const paneWidth = () => Math.max(1, window.innerWidth || document.documentElement.clientWidth || 1);
    const resistance = (distance: number, width: number) => {
      if (distance <= width) return distance;
      return width + (distance - width) * 0.16;
    };
    const resetGesture = (transition: PhonePaneTransition) => {
      active = false;
      intent = "pending";
      targetPane = null;
      setPhonePaneTransition(transition);
      setPhonePaneDragOffset(0);
    };
    const onStart = (e: TouchEvent) => {
      const t = e.touches[0];
      if (!t) return;
      const state = useUiStore.getState();
      startX = t.clientX;
      startY = t.clientY;
      lastX = startX;
      lastAt = performance.now();
      velocityX = 0;
      startPane = state.phonePane;
      allowsHorizontalPaneGesture =
        startPane === "sidebar" ||
        (startPane === "list" && startX <= EDGE_PX);
      active = allowsHorizontalPaneGesture;
      intent = "pending";
      targetPane = null;
      if (active) setPhonePaneTransition("none");
    };
    const onMove = (e: TouchEvent) => {
      if (!allowsHorizontalPaneGesture || !active) return;
      const t = e.touches[0];
      if (!t) return;
      const now = performance.now();
      const dt = Math.max(1, now - lastAt);
      velocityX = (t.clientX - lastX) / dt;
      lastX = t.clientX;
      lastAt = now;

      const dx = t.clientX - startX;
      const absDx = Math.abs(dx);
      const dy = Math.abs(t.clientY - startY);
      if (intent === "pending") {
        if (dy > PHONE_PANE_VERTICAL_CANCEL_PX && dy > absDx) {
          resetGesture("settle");
          return;
        }
        if (absDx <= PHONE_PANE_INTENT_PX || absDx <= dy) return;
        intent = "horizontal";
      }

      if (intent !== "horizontal") return;
      e.preventDefault();

      if (!targetPane) {
        if (startPane === "sidebar" && dx < 0) targetPane = "list";
        if (startPane === "list" && dx > 0) targetPane = "sidebar";
      }

      const width = paneWidth();
      if (targetPane === "list") {
        setPhonePaneDragOffset(-resistance(Math.max(0, -dx), width));
      } else if (targetPane === "sidebar") {
        setPhonePaneDragOffset(resistance(Math.max(0, dx), width));
      } else {
        setPhonePaneDragOffset(Math.sign(dx) * Math.min(absDx * 0.18, 36));
      }
    };
    const onEnd = () => {
      if (!active) return;
      if (intent !== "horizontal") {
        resetGesture("settle");
        return;
      }

      const dx = lastX - startX;
      const width = paneWidth();
      const direction = targetPane === "list" ? -1 : 1;
      const distance = targetPane ? Math.max(0, direction * dx) : 0;
      const velocity = targetPane ? direction * velocityX : 0;
      const threshold = Math.min(PHONE_PANE_COMMIT_MAX_PX, width * PHONE_PANE_COMMIT_RATIO);
      const shouldCommit =
        targetPane &&
        (distance >= threshold || (distance >= 22 && velocity >= PHONE_PANE_FAST_PX_PER_MS));

      active = false;
      intent = "pending";
      if (shouldCommit && targetPane) {
        setPhonePaneTransition("slide");
        setPhonePaneDragOffset(0);
        useUiStore.getState().setPhonePane(targetPane);
      } else {
        setPhonePaneTransition("settle");
        setPhonePaneDragOffset(0);
      }
      targetPane = null;
    };
    window.addEventListener("touchstart", onStart, { passive: true });
    window.addEventListener("touchmove", onMove, { passive: false });
    window.addEventListener("touchend", onEnd, { passive: true, capture: true });
    window.addEventListener("touchcancel", onEnd, { passive: true, capture: true });
    return () => {
      window.removeEventListener("touchstart", onStart);
      window.removeEventListener("touchmove", onMove);
      window.removeEventListener("touchend", onEnd, { capture: true });
      window.removeEventListener("touchcancel", onEnd, { capture: true });
    };
  }, [isPhone]);

  useEffect(() => {
    if (!isPhone) return;
    const suppress = () => setSuppressNextPhonePaneTransition(true);
    window.addEventListener("skim-suppress-next-phone-pane-transition", suppress);
    return () => window.removeEventListener("skim-suppress-next-phone-pane-transition", suppress);
  }, [isPhone]);

  useEffect(() => {
    if (!suppressNextPhonePaneTransition) return;
    const id = window.requestAnimationFrame(() => setSuppressNextPhonePaneTransition(false));
    return () => window.cancelAnimationFrame(id);
  }, [phonePane, suppressNextPhonePaneTransition]);

  // Disable default context menu
  useEffect(() => {
    const prevent = (e: MouseEvent) => e.preventDefault();
    document.addEventListener("contextmenu", prevent);
    return () => document.removeEventListener("contextmenu", prevent);
  }, []);

  // Keyboard shortcuts
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      // Block devtools shortcuts everywhere
      const key = e.key.toLowerCase();
      if (
        (key === "i" && (e.metaKey || e.ctrlKey) && e.altKey) || // Cmd+Option+I
        (key === "j" && (e.metaKey || e.ctrlKey) && e.altKey) || // Cmd+Option+J
        (key === "c" && (e.metaKey || e.ctrlKey) && e.shiftKey) || // Cmd+Shift+C
        (key === "u" && (e.metaKey || e.ctrlKey)) || // Cmd+U (view source)
        e.key === "F12"
      ) {
        e.preventDefault();
        return;
      }

      // Global shortcuts — work even when typing in inputs
      if (e.key === "," && (e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        useUiStore.getState().setShowSettings(true);
        return;
      }

      if (
        e.target instanceof HTMLInputElement ||
        e.target instanceof HTMLTextAreaElement
      )
        return;

      if (e.key === "Escape") {
        useUiStore.getState().setShowAddFeed(false);
        useUiStore.getState().setShowSettings(false);
      }
      if (e.key === "[" && (e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        useUiStore.getState().toggleSidebar();
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, []);

  if (isPhone) {
    const paneIndex = phonePane === "sidebar" ? 0 : phonePane === "list" ? 1 : 2;
    const opmlToast = opmlImportStatus && <OpmlImportToast status={opmlImportStatus} isPhone />;
    const phonePaneTransitionStyle =
      suppressNextPhonePaneTransition || phonePaneTransition === "none"
        ? "none"
        : phonePaneTransition === "settle"
          ? `transform ${PHONE_PANE_SETTLE_MS}ms ${PHONE_SETTLE_EASING}`
          : `transform ${PHONE_PANE_SLIDE_MS}ms ${PHONE_SLIDE_EASING}`;
    return (
      <div className="flex flex-col h-full w-full overflow-hidden">
        <div className="flex-1 min-h-0 relative overflow-hidden">
          <div
            className="flex h-full w-[300%]"
            style={{
              transform: `translate3d(calc(${-paneIndex * (100 / 3)}% + ${phonePaneDragOffset}px), 0, 0)`,
              transition: phonePaneTransitionStyle,
              willChange: "transform",
              backfaceVisibility: "hidden",
            }}
          >
            <div
              className="w-1/3 h-full flex-shrink-0 overflow-hidden flex"
              style={{
                pointerEvents: paneIndex === 0 ? "auto" : "none",
                contain: "layout paint",
              }}
              aria-hidden={paneIndex !== 0}
            >
              <Sidebar />
            </div>
            <div
              className="w-1/3 h-full flex-shrink-0 overflow-hidden flex"
              style={{
                pointerEvents: paneIndex === 1 ? "auto" : "none",
                contain: "layout paint",
              }}
              aria-hidden={paneIndex !== 1}
            >
              <ArticleList />
            </div>
            <div
              className="w-1/3 h-full flex-shrink-0 overflow-hidden flex"
              style={{
                pointerEvents: paneIndex === 2 ? "auto" : "none",
                contain: "layout paint",
              }}
              aria-hidden={paneIndex !== 2}
            >
              {selectedArticleId ? <ArticleDetail /> : <div className="flex-1" />}
            </div>
          </div>
        </div>
        {opmlToast}
        {showAddFeed && <AddFeedDialog />}
        {showSettings && <SettingsDialog />}
        {showBootDisclaimer && <AIBootDisclaimer onDismiss={() => setShowBootDisclaimer(false)} />}
      </div>
    );
  }

  const opmlToast = opmlImportStatus && <OpmlImportToast status={opmlImportStatus} />;

  return (
    <div className="flex flex-col h-full w-full">
      {/* Full-width drag region for window movement */}
      <div
        className="h-12 w-full flex-shrink-0 absolute top-0 left-0 right-0 z-10"
        data-tauri-drag-region
        style={{ WebkitAppRegion: "drag" } as React.CSSProperties}
      />
      <div className="flex flex-1 min-h-0">
        <Sidebar />
        <div className="flex flex-1 min-w-0">
          <ArticleList />
          {selectedArticleId ? (
            <ArticleDetail />
          ) : (
            <div
              className={`flex-1 flex flex-col items-center justify-center bg-bg-primary/60 select-none ${listCollapsed ? "cursor-pointer" : ""}`}
              onClick={() => {
                const state = useUiStore.getState();
                if (state.listCollapsed) state.toggleList();
              }}
            >
              <div className="text-text-muted flex items-center gap-2">
                {listCollapsed && (
                  <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                    <rect x="3" y="3" width="18" height="18" rx="2" />
                    <path d="M9 3v18" />
                  </svg>
                )}
                <span className="text-sm">{listCollapsed ? "Show article list" : "Select an article to read"}</span>
              </div>
            </div>
          )}
        </div>
      </div>
      {opmlToast}
      {showAddFeed && <AddFeedDialog />}
      {showSettings && <SettingsDialog />}
      {showBootDisclaimer && <AIBootDisclaimer onDismiss={() => setShowBootDisclaimer(false)} />}
    </div>
  );
}

function OpmlImportToast({ status, isPhone = false }: { status: OpmlImportStatus; isPhone?: boolean }) {
  const active = status.phase === "importing" || status.phase === "refreshing";
  const isError = status.phase === "error";
  return (
    <div
      className={`fixed ${isPhone ? "left-3 right-3" : "right-5"} rounded-xl border shadow-2xl backdrop-blur-xl flex items-center gap-3`}
      style={{
        bottom: isPhone ? "calc(env(safe-area-inset-bottom, 0px) + 16px)" : 20,
        zIndex: 60,
        maxWidth: isPhone ? undefined : 420,
        padding: "12px 14px",
        background: "rgba(22, 27, 34, 0.94)",
        borderColor: isError ? "rgba(248, 81, 73, 0.36)" : "rgba(88, 166, 255, 0.28)",
      }}
      role="status"
      aria-live="polite"
    >
      {active ? (
        <svg className="smooth-spin text-accent flex-shrink-0" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
          <path d="M21 12a9 9 0 1 1-6.219-8.56" />
        </svg>
      ) : (
        <span
          className={`rounded-full flex-shrink-0 ${isError ? "bg-danger" : "bg-success"}`}
          style={{ width: 8, height: 8 }}
        />
      )}
      <span className={isError ? "text-danger" : "text-text-primary"} style={{ fontSize: 13, lineHeight: 1.45 }}>
        {status.message}
      </span>
    </div>
  );
}

export default App;
