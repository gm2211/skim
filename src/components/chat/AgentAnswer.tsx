import { Children, isValidElement, type ReactNode } from "react";
import Markdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { openUrl } from "@tauri-apps/plugin-opener";
import type { AgentStep, ChatSource } from "../../services/commands";
import "./chat-markdown.css";

const CITATION_HREF = "#skim-article-";

/** Design mock: which of the four cited-item styles to render. */
export type CitationStyle = "row" | "headline" | "card" | "gutter";
function citationStyle(): CitationStyle {
  try {
    const value = localStorage.getItem("skim.citationStyle");
    if (value === "headline" || value === "card" || value === "gutter") return value;
  } catch { /* storage unavailable */ }
  return "row";
}

/**
 * Turn each [n] that names a numbered article into a link, so an answer that
 * lists matches can be clicked straight through to the article.
 */
export function linkCitations(content: string, sources: ChatSource[]): string {
  return content.replace(/\[(\d{1,3})\](?!\()/g, (match, digits: string) => {
    const source = sources[Number(digits) - 1];
    if (!source || source.source_type === "web") return match;
    return `[[${digits}]](${CITATION_HREF}${encodeURIComponent(source.id)})`;
  });
}

type HastNode = { type: string; tagName?: string; value?: string; properties?: { href?: unknown }; children?: HastNode[] };

/** The article a paragraph or list item opens with, when it starts with a [n] citation. */
function leadingCitation(node: HastNode | undefined): string | null {
  const first = node?.children?.find((child) => !(child.type === "text" && !child.value?.trim()));
  const href = first?.type === "element" && first.tagName === "a" ? first.properties?.href : null;
  return typeof href === "string" && href.startsWith(CITATION_HREF) ? decodeURIComponent(href.slice(CITATION_HREF.length)) : null;
}

/** Splits a cited item's children into its bold title and the description after it. */
function splitItem(children: ReactNode) {
  const parts = Children.toArray(children);
  parts.shift(); // the [n] link
  while (typeof parts[0] === "string" && !parts[0].trim()) parts.shift();
  let title: ReactNode = null;
  if (isValidElement(parts[0]) && parts[0].type === "strong") {
    title = (parts.shift() as React.ReactElement<{ children: ReactNode }>).props.children;
    const next = parts[0] as unknown;
    if (typeof next === "string") parts[0] = next.replace(/^\s*[-–—:]\s*/, "");
  }
  return { title, rest: parts };
}

function formatDate(seconds: number | null): string | null {
  if (!seconds) return null;
  return new Date(seconds * 1000).toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

function CitedItem({ id, number, source, style, children, onOpenArticle }: {
  id: string;
  number: number;
  source: ChatSource | undefined;
  style: CitationStyle;
  children: ReactNode;
  onOpenArticle: (id: string) => void;
}) {
  const open = () => {
    // A drag that selected text is a selection, not a click.
    if (window.getSelection()?.toString()) return;
    onOpenArticle(id);
  };
  const { title, rest } = splitItem(children);
  const meta = [source?.feed_title, formatDate(source?.published_at ?? null)].filter(Boolean).join(" · ");
  const common = {
    role: "link" as const,
    tabIndex: 0,
    title: source ? `Open “${source.title}”` : undefined,
    onClick: open,
    onKeyDown: (event: React.KeyboardEvent) => { if (event.key === "Enter") { event.preventDefault(); onOpenArticle(id); } },
  };
  const arrow = (
    <svg className="cited-arrow" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden>
      <path d="M5 12h14M13 6l6 6-6 6" />
    </svg>
  );

  if (style === "row") {
    return (
      <div {...common} className="cited-item cited-row">
        <span className="cited-num">{number}</span>
        <span className="cited-body">{title && <strong>{title}</strong>}{title && " — "}{rest}</span>
        {arrow}
      </div>
    );
  }
  if (style === "headline") {
    return (
      <div {...common} className="cited-item cited-headline">
        {title && <span className="cited-title">{title}</span>}
        <span className="cited-desc">{rest}</span>
        {meta && <span className="cited-meta">{meta}</span>}
      </div>
    );
  }
  if (style === "card") {
    return (
      <div {...common} className="cited-item cited-card">
        <div className="cited-meta">
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden>
            <path d="M2 4h7a3 3 0 0 1 3 3v13a2 2 0 0 0-2-2H2zM22 4h-7a3 3 0 0 0-3 3v13a2 2 0 0 1 2-2h8z" />
          </svg>
          <span className="truncate">{meta}</span>
          <span className="cited-num">[{number}]</span>
        </div>
        {title && <div className="cited-title">{title}</div>}
        <div className="cited-desc">{rest}</div>
      </div>
    );
  }
  return (
    <div {...common} className="cited-item cited-gutter">
      <span className="cited-num">{number}</span>
      <div className="cited-body">
        {title && <div className="cited-title">{title}{arrow}</div>}
        <div className="cited-desc">{rest}</div>
        {meta && <div className="cited-meta">{meta}</div>}
      </div>
    </div>
  );
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

/** An agent answer, with its [n] citations linked to the articles. */
export function AgentAnswer({ content, sources, onOpenArticle }: {
  content: string;
  sources: ChatSource[];
  onOpenArticle: (id: string) => void;
}) {
  const style = citationStyle();
  const cited = (node: HastNode | undefined, children: ReactNode) => {
    const id = leadingCitation(node);
    if (!id) return null;
    const index = sources.findIndex((source) => source.id === id);
    return (
      <CitedItem id={id} number={index + 1} source={sources[index]} style={style} onOpenArticle={onOpenArticle}>
        {children}
      </CitedItem>
    );
  };
  return (
    <div className="chat-markdown text-text-primary" style={{ fontSize: 14 }}>
      <Markdown remarkPlugins={[remarkGfm]} skipHtml components={{
        p: ({ node, children }) => cited(node as HastNode, children) ?? <p>{children}</p>,
        li: ({ node, children }) => {
          const item = cited(node as HastNode, children);
          return item ? <li className="cited-li">{item}</li> : <li>{children}</li>;
        },
        a: ({ href, children }) => {
          if (href?.startsWith(CITATION_HREF)) {
            const id = decodeURIComponent(href.slice(CITATION_HREF.length));
            return (
              <a href={href} className="agent-citation" onClick={(event) => { event.preventDefault(); event.stopPropagation(); onOpenArticle(id); }}>
                {children}
              </a>
            );
          }
          return href && /^https?:\/\//i.test(href)
            ? <a href={href} target="_blank" rel="noopener noreferrer" onClick={(event) => { event.preventDefault(); event.stopPropagation(); void openUrl(href).catch(() => {}); }}>{children}</a>
            : <span>{children}</span>;
        },
        table: ({ children }) => <div className="chat-table-scroll"><table>{children}</table></div>,
        img: ({ alt }) => <span>{alt}</span>,
      }}>{linkCitations(content, sources)}</Markdown>
    </div>
  );
}
