import type { CSSProperties } from "react";
import { useUiStore } from "../../stores/uiStore";
import { SkimTitle } from "./SkimTitle";

/** Branding remains visible when navigation is hidden, clear of window controls. */
export function CollapsedSidebarTitlebar({ showTitle = true }: { showTitle?: boolean }) {
  return (
    <div
      className="sidebar-header-desktop flex flex-shrink-0 items-center relative z-20"
      data-tauri-drag-region
      style={{ height: 40, paddingLeft: 80, paddingRight: 8, WebkitAppRegion: "drag" } as CSSProperties}
    >
      {showTitle && <SkimTitle />}
      <div className="flex-1" style={{ minWidth: 48 }} />
      <button
        onClick={() => useUiStore.getState().toggleSidebar()}
        className="sidebar-header-action tap-target text-text-muted hover:text-text-primary transition-colors rounded-lg hover:bg-white/10"
        title="Expand sidebar"
        aria-label="Expand sidebar"
      >
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true">
          <rect x="3" y="3" width="18" height="18" rx="2" />
          <path d="M9 3v18" />
        </svg>
      </button>
    </div>
  );
}
