import Markdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { openUrl } from "@tauri-apps/plugin-opener";
import type { AgentStep, ChatSource } from "../../services/commands";
import { citationOrder, citedSource } from "../../lib/chatCitations";
import "./chat-markdown.css";

export const CITATION_HREF = "#skim-article-";

/**
 * Turn each [n] that names an article, and each [wN] that names a web result,
 * into a small numbered chip, numbered as the reader meets them so it matches
 * the card under the answer.
 */
export function linkCitations(content: string, sources: ChatSource[]): string {
  const labels = new Map(citationOrder(sources, content).map(({ source, label }) => [source.id, label]));
  // Chips stay on the line of the word they follow, and a run like [3][1] never splits.
  return content.replace(/ ?\[(w?)(\d{1,3})\](?!\()/gi, (match, web: string, digits: string) => {
    const source = citedSource(sources, web, digits);
    const label = source && labels.get(source.id);
    if (!source || !label) return match;
    const lead = match.startsWith(" ") ? "\u00a0" : "\u2060";
    return `${lead}[${label}](${CITATION_HREF}${encodeURIComponent(source.id)})`;
  });
}

export function AgentSteps({ steps }: { steps: AgentStep[] }) {
  if (!steps.length) return null;
  return (
    <ul className="text-text-muted" style={{ fontSize: 12, margin: "2px 0 8px", display: "grid", gap: 2 }} aria-label="What Skim did">
      {steps.map((step, index) => (
        <li key={index} className="truncate">{step.label}</li>
      ))}
    </ul>
  );
}

/** A feed's initial on a colour picked from its name, standing in for a favicon. */
export function FeedMark({ name, size = 16 }: { name: string; size?: number }) {
  let hash = 0;
  for (const ch of name) hash = (hash * 31 + ch.charCodeAt(0)) >>> 0;
  return (
    <span className="feed-mark" aria-hidden style={{ width: size, height: size, fontSize: size * 0.6, background: `hsl(${hash % 360} 45% 34%)` }}>
      {name.trim().charAt(0).toUpperCase()}
    </span>
  );
}

/** The chip for a citation link made by `linkCitations`, or null for any other link. */
export function citationChip(href: string | undefined, children: React.ReactNode, { titles, onOpenArticle, onHoverSource, highlightId }: {
  titles: Map<string, string>;
  onOpenArticle: (id: string) => void;
  onHoverSource?: (id: string | null) => void;
  highlightId?: string | null;
}) {
  if (!href?.startsWith(CITATION_HREF)) return null;
  const id = decodeURIComponent(href.slice(CITATION_HREF.length));
  return (
    <a
      href={href}
      className={`cite-chip${id === highlightId ? " active" : ""}`}
      title={titles.get(id)}
      onMouseEnter={() => onHoverSource?.(id)}
      onMouseLeave={() => onHoverSource?.(null)}
      onClick={(event) => { event.preventDefault(); onOpenArticle(id); }}
    >
      {children}
    </a>
  );
}

/** An agent answer, with its [n] citations as numbered chips that open the articles. */
export function AgentAnswer({ content, sources, onOpenArticle, onHoverSource, highlightId }: {
  content: string;
  sources: ChatSource[];
  onOpenArticle: (id: string) => void;
  /** Called with the cited article under the pointer, so its card can light up. */
  onHoverSource?: (id: string | null) => void;
  /** The article whose card is selected; its chips light up to match. */
  highlightId?: string | null;
}) {
  const titles = new Map(sources.map((source) => [source.id, source.title]));
  return (
    <div className="chat-markdown text-text-primary" style={{ fontSize: 14 }}>
      <Markdown remarkPlugins={[remarkGfm]} skipHtml components={{
        a: ({ href, children }) => {
          const chip = citationChip(href, children, { titles, onOpenArticle, onHoverSource, highlightId });
          if (chip) return chip;
          return href && /^https?:\/\//i.test(href)
            ? <a href={href} target="_blank" rel="noopener noreferrer" onClick={(event) => { event.preventDefault(); void openUrl(href).catch(() => {}); }}>{children}</a>
            : <span>{children}</span>;
        },
        table: ({ children }) => <div className="chat-table-scroll"><table>{children}</table></div>,
        img: ({ alt }) => <span>{alt}</span>,
      }}>{linkCitations(content, sources)}</Markdown>
    </div>
  );
}

function formatDate(seconds: number | null): string | null {
  if (!seconds) return null;
  return new Date(seconds * 1000).toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

/** One cited source as a card: the number the answer's chip carries, the feed, and the title. */
export function SourceTile({ source, label, active, onOpen, onHover, id, inListbox = false }: {
  source: ChatSource;
  label: number;
  active: boolean;
  onOpen: () => void;
  onHover?: () => void;
  id?: string;
  /** In the palette the tiles are listbox options driven by the arrow keys; elsewhere each is its own button. */
  inListbox?: boolean;
}) {
  const isWeb = source.source_type === "web";
  // Web results name their site when Skim knows it.
  const site = isWeb ? (source.feed_title && source.feed_title !== "Web" ? source.feed_title : "Web") : source.feed_title;
  const date = formatDate(source.published_at);
  return (
    <div
      id={id}
      {...(inListbox
        ? { role: "option", "aria-selected": active }
        : { role: "button", tabIndex: 0, onKeyDown: (event: React.KeyboardEvent) => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); onOpen(); } } })}
      className={`source-tile${active ? " active" : ""}`}
      onMouseMove={onHover}
      onClick={onOpen}
    >
      <div className="source-tile-kicker">
        <span className="source-tile-num">{label}</span>
        {isWeb ? (
          <span className="feed-mark web" aria-hidden style={{ width: 16, height: 16 }}>
            <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2">
              <circle cx="12" cy="12" r="10" /><path d="M2 12h20" /><path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z" />
            </svg>
          </span>
        ) : <FeedMark name={site} />}
        <span className="truncate">{site}</span>
        {date && <span className="source-tile-date">· {date}</span>}
      </div>
      <div className="source-tile-title">{source.title}</div>
    </div>
  );
}
