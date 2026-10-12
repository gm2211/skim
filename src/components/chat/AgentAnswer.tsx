import Markdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { openUrl } from "@tauri-apps/plugin-opener";
import type { AgentStep, ChatSource } from "../../services/commands";
import "./chat-markdown.css";

const CITATION_HREF = "#skim-article-";

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
  return (
    <div className="chat-markdown text-text-primary" style={{ fontSize: 14 }}>
      <Markdown remarkPlugins={[remarkGfm]} skipHtml components={{
        a: ({ href, children }) => {
          if (href?.startsWith(CITATION_HREF)) {
            const id = decodeURIComponent(href.slice(CITATION_HREF.length));
            return (
              <a href={href} className="agent-citation" onClick={(event) => { event.preventDefault(); onOpenArticle(id); }}>
                {children}
              </a>
            );
          }
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
