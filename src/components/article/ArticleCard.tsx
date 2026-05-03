import { useMemo, useRef } from "react";
import { useSettings } from "../../hooks/useSettings";
import type { Article } from "../../services/types";

const PRIORITY_COLORS: Record<number, string> = {
  5: "#ef4444", // red
  4: "#f97316", // orange
  3: "#3b82f6", // blue
  2: "#6b7280", // gray
  1: "#4b5563", // dim gray
};

const PRIORITY_LABELS: Record<number, string> = {
  5: "Must Read",
  4: "Important",
  3: "Worth Reading",
  2: "Routine",
  1: "Skip",
};

interface Props {
  article: Article;
  triage?: { priority: number; reason: string } | null;
  themeTags?: { themeId: string; label: string }[];
  isSelected: boolean;
  onSelect: () => void;
  onContextMenu?: (e: React.MouseEvent) => void;
}

function timeAgo(timestamp: number | null): string {
  if (!timestamp) return "";
  const now = Date.now() / 1000;
  const diff = now - timestamp;

  if (diff < 60) return "just now";
  if (diff < 3600) return `${Math.floor(diff / 60)}m`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h`;
  if (diff < 604800) return `${Math.floor(diff / 86400)}d`;
  return new Date(timestamp * 1000).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
  });
}

function extractImageUrl(html: string | null): string | null {
  if (!html) return null;
  const match = html.match(/<img[^>]+src=["']([^"']+)["']/i);
  if (!match) return null;
  const src = match[1];
  // Skip tiny tracking pixels and icons
  if (src.includes("feedburner") || src.includes("pixel") || src.includes("badge")) return null;
  return src;
}

export function ArticleCard({ article, triage, themeTags, isSelected, onSelect, onContextMenu }: Props) {
  const imageUrl = useMemo(() => extractImageUrl(article.content_html), [article.content_html]);
  const { data: settings } = useSettings();
  const showExcerpt = settings?.appearance?.show_excerpt_in_list ?? false;
  const longPressTimer = useRef<number | null>(null);
  const longPressFired = useRef(false);
  const longPressStart = useRef<{ x: number; y: number } | null>(null);
  const touchMoved = useRef(false);

  return (
    <div
      onClick={(e) => {
        if (longPressFired.current || touchMoved.current) {
          longPressFired.current = false;
          touchMoved.current = false;
          e.preventDefault();
          e.stopPropagation();
          return;
        }
        onSelect();
      }}
      onContextMenu={onContextMenu}
      onPointerDown={onContextMenu ? (e) => {
        if (e.pointerType !== "touch") return;
        longPressFired.current = false;
        touchMoved.current = false;
        longPressStart.current = { x: e.clientX, y: e.clientY };
        if (longPressTimer.current) window.clearTimeout(longPressTimer.current);
        if (onContextMenu) {
          longPressTimer.current = window.setTimeout(() => {
            longPressFired.current = true;
            if (navigator.vibrate) navigator.vibrate(8);
            onContextMenu({
              preventDefault: () => {},
              stopPropagation: () => {},
              clientX: longPressStart.current?.x ?? 0,
              clientY: longPressStart.current?.y ?? 0,
            } as unknown as React.MouseEvent);
          }, 450);
        }
      } : undefined}
      onPointerMove={onContextMenu ? (e) => {
        if (longPressStart.current && longPressTimer.current) {
          const dx = Math.abs(e.clientX - longPressStart.current.x);
          const dy = Math.abs(e.clientY - longPressStart.current.y);
          if (dx > 10 || dy > 10) {
            touchMoved.current = true;
            window.clearTimeout(longPressTimer.current);
            longPressTimer.current = null;
          }
        }
      } : undefined}
      onPointerUp={onContextMenu ? () => {
        if (longPressTimer.current) { window.clearTimeout(longPressTimer.current); longPressTimer.current = null; }
      } : undefined}
      onPointerCancel={onContextMenu ? () => {
        if (longPressTimer.current) { window.clearTimeout(longPressTimer.current); longPressTimer.current = null; }
        longPressStart.current = null;
      } : undefined}
      className={`cursor-pointer transition-colors border-b border-white/5 select-none relative overflow-hidden ${
        isSelected
          ? "bg-accent/15"
          : "hover:bg-white/5"
      }`}
      style={{ padding: "14px 20px", touchAction: "pan-y", WebkitTouchCallout: "none", WebkitUserSelect: "none" }}
    >
      {isSelected && (
        <div
          className="absolute left-0 top-0 bottom-0 bg-accent"
          style={{ width: 3 }}
          aria-hidden
        />
      )}
      <div
        className="flex items-start justify-between gap-3 relative"
      >
        <div className="min-w-0 flex-1">
          <h3
            className={`leading-snug line-clamp-2 ${
              article.is_read
                ? "text-text-muted font-normal"
                : "text-text-primary font-medium"
            }`}
            style={{ fontSize: 15, marginBottom: 6 }}
          >
            {article.title}
          </h3>
          {showExcerpt && article.content_text ? (
            <p
              className="text-text-muted line-clamp-2"
              style={{ fontSize: 13, lineHeight: 1.5, marginBottom: 8 }}
            >
              {article.content_text.slice(0, 160)}
            </p>
          ) : null}
          <div className="flex items-center gap-2 flex-wrap">
            {!article.is_read && (
              <span
                className="rounded-full bg-accent flex-shrink-0"
                style={{ width: 8, height: 8 }}
                title="Unread"
              />
            )}
            {triage && (
              <span
                className="rounded-full flex-shrink-0 cursor-help"
                style={{ width: 8, height: 8, backgroundColor: PRIORITY_COLORS[triage.priority] ?? "#6b7280" }}
                title={
                  triage.reason
                    ? `${PRIORITY_LABELS[triage.priority]} — ${triage.reason}`
                    : PRIORITY_LABELS[triage.priority]
                }
              />
            )}
            {article.feed_icon_url && (
              <img
                src={article.feed_icon_url}
                alt=""
                className="rounded-sm flex-shrink-0"
                style={{ width: 14, height: 14 }}
                loading="lazy"
                onError={(e) => { (e.target as HTMLImageElement).style.display = "none"; }}
              />
            )}
            <span className="text-accent truncate" style={{ fontSize: 12 }}>
              {article.feed_title}
            </span>
            <span className="text-text-muted" style={{ fontSize: 12 }}>
              {timeAgo(article.published_at ?? article.fetched_at)}
            </span>
            {themeTags?.map((tag) => (
              <span
                key={tag.themeId}
                className="rounded-full bg-accent/10 text-accent"
                style={{ padding: "1px 8px", fontSize: 11 }}
              >
                {tag.label}
              </span>
            ))}
          </div>
        </div>
        <div className="flex flex-col items-center gap-1.5 flex-shrink-0">
          {imageUrl ? (
            <img
              src={imageUrl}
              alt=""
              className="rounded-md object-cover"
              style={{ width: 72, height: 72 }}
              loading="lazy"
              onError={(e) => { (e.target as HTMLImageElement).style.display = "none"; }}
            />
          ) : null}
          <div className="flex items-center gap-1.5">
            {article.is_starred && (
              <svg
                width="12"
                height="12"
                viewBox="0 0 24 24"
                fill="currentColor"
                className="text-warning"
              >
                <polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2" />
              </svg>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
