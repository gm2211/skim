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

function App() {
  const { showAddFeed, showSettings, selectedArticleId, listCollapsed, isPhone, phonePane } = useUiStore();
  const qc = useQueryClient();
  const [showBootDisclaimer, setShowBootDisclaimer] = useState(true);
  const [opmlImportStatus, setOpmlImportStatus] = useState<OpmlImportStatus | null>(null);
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
    let startPane = useUiStore.getState().phonePane;
    let allowsHorizontalPaneGesture = false;
    let cancelled = false;
    const EDGE_PX = 56;
    const TRIGGER_PX = 72;
    const INTENT_PX = 10;
    const onStart = (e: TouchEvent) => {
      const t = e.touches[0];
      if (!t) return;
      const state = useUiStore.getState();
      startX = t.clientX;
      startY = t.clientY;
      startPane = state.phonePane;
      allowsHorizontalPaneGesture =
        startPane === "sidebar" ||
        (startPane === "list" && startX <= EDGE_PX);
      cancelled = false;
    };
    const onMove = (e: TouchEvent) => {
      if (!allowsHorizontalPaneGesture || cancelled) return;
      const t = e.touches[0];
      if (!t) return;
      const dx = t.clientX - startX;
      const absDx = Math.abs(dx);
      const dy = Math.abs(t.clientY - startY);
      if (dy > 40 && dy > absDx) {
        cancelled = true;
        return;
      }

      if (absDx > INTENT_PX && absDx > dy) {
        e.preventDefault();
      }

      if (startPane === "sidebar" && dx < -TRIGGER_PX) {
        cancelled = true;
        useUiStore.getState().setPhonePane("list");
      } else if (startPane === "list" && dx > TRIGGER_PX) {
        cancelled = true;
        useUiStore.getState().setPhonePane("sidebar");
      }
    };
    window.addEventListener("touchstart", onStart, { passive: true });
    window.addEventListener("touchmove", onMove, { passive: false });
    return () => {
      window.removeEventListener("touchstart", onStart);
      window.removeEventListener("touchmove", onMove);
    };
  }, [isPhone]);

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
    return (
      <div className="flex flex-col h-full w-full overflow-hidden">
        <div className="flex-1 min-h-0 relative overflow-hidden">
          <div
            className="flex h-full w-[300%]"
            style={{
              transform: `translate3d(${-paneIndex * (100 / 3)}%, 0, 0)`,
              transition: "transform 0.42s cubic-bezier(0.2, 0.82, 0.18, 1)",
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
