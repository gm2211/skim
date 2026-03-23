import { useMemo } from "react";
import type { Article } from "../../services/types";

interface Props {
  article: Article;
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

export function ArticleCard({ article, isSelected, onSelect, onContextMenu }: Props) {
  const imageUrl = useMemo(() => extractImageUrl(article.content_html), [article.content_html]);

  return (
    <div
      onClick={onSelect}
      onContextMenu={onContextMenu}
      className={`cursor-pointer transition-colors border-b border-white/5 select-none ${
        isSelected
          ? "bg-white/10"
          : "hover:bg-white/5"
      }`}
      style={{ padding: "14px 20px" }}
    >
      <div className="flex items-start justify-between gap-3">
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
          {article.content_text && (
            <p
              className="text-text-muted line-clamp-2"
              style={{ fontSize: 13, lineHeight: 1.5, marginBottom: 8 }}
            >
              {article.content_text.slice(0, 160)}
            </p>
          )}
          <div className="flex items-center gap-2">
            <span className="text-accent truncate" style={{ fontSize: 12 }}>
              {article.feed_title}
            </span>
            <span className="text-text-muted" style={{ fontSize: 12 }}>
              {timeAgo(article.published_at ?? article.fetched_at)}
            </span>
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
            {!article.is_read && (
              <div
                className="rounded-full bg-accent"
                style={{ width: 8, height: 8 }}
                title="Unread"
              />
            )}
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
