import { useEffect, useRef } from "react";
import { useQuery } from "@tanstack/react-query";
import { CollapsedSidebarTitlebar } from "../layout/CollapsedSidebarTitlebar";
import { useRefreshAllFeeds } from "../../hooks/useFeeds";
import { useDispatch } from "../../hooks/useDispatch";
import { useSettings, useUpdateSettings } from "../../hooks/useSettings";
import { useUiStore } from "../../stores/uiStore";
import { TODAY_PAGE_COUNT, formatWindowDate, themeColor } from "../../lib/todayEdition";
import { DISPATCH_DAY_CHOICES, PAPER_NAME, spanLabel, splitCitations, withoutCitations } from "../../lib/dispatch";
import * as commands from "../../services/commands";
import type { DispatchArticle, DispatchEdition, DispatchTheme } from "../../services/types";
import { ModelPicker } from "../common/ModelPicker";
import { ChatIcon, RefreshIcon } from "../ui/icons";
import { openAgentChat } from "../../stores/agentChatStore";
import { ReaderSelectionAsk } from "../article/ReaderSelectionAsk";
import { useAgentContext } from "../../hooks/useAgentContext";
import type { AgentStory } from "../../services/commands";
import { IconButton } from "../common/IconButton";
import { SettingsCog } from "../common/SettingsCog";
import { AiErrorText, openAiSettings } from "../common/AiSettingsButton";
import "./TodayFrontPage.css";
import "./TodayStorySkeleton.css";
import "./Dispatch.css";

function themeForAgent(theme: DispatchTheme, index: number): AgentStory {
  return {
    story_id: `dispatch-theme-${index}`,
    title: theme.headline,
    summary: [theme.dek, ...theme.body.map(withoutCitations)].filter(Boolean).join("\n\n") || null,
    article_ids: theme.article_ids,
  };
}

/** A paragraph with its `[n]` citations as small links to the reports. */
function Cited({ text, articles, onOpen }: { text: string; articles: (DispatchArticle | undefined)[]; onOpen: (id: string) => void }) {
  return <>{splitCitations(text).map((part, index) => "text" in part ? <span key={index}>{part.text}</span> : (
    <sup key={index} className="dispatch-cites">
      {part.cites.map((n) => {
        const article = articles[n - 1];
        return article
          ? <button key={n} type="button" className="dispatch-cite" title={`${article.publication}: ${article.title}`} onClick={() => onOpen(article.id)}>{n}</button>
          : null;
      })}
    </sup>
  ))}</>;
}

function Bars({ widths }: { widths: string[] }) {
  return <div className="dispatch-bars" aria-hidden="true">
    {widths.map((width, index) => <span key={index} className="today-story-skeleton-bar" style={{ width }} />)}
  </div>;
}

function Piece({ theme, index, edition, isWriting, onOpen, onAsk, onAskAbout, image }: {
  theme: DispatchTheme;
  index: number;
  edition: DispatchEdition;
  isWriting: boolean;
  onOpen: (id: string) => void;
  onAsk: () => void;
  /** Ask about a passage highlighted in the piece. */
  onAskAbout: (text: string) => void;
  image?: string | null;
}) {
  const pieceRef = useRef<HTMLElement>(null);
  const lead = index === 0;
  const byId = new Map(edition.articles.map((article) => [article.id, article]));
  const articles = theme.article_ids.map((id) => byId.get(id));
  const written = theme.body.length > 0;
  const color = themeColor(theme.kicker);
  const reports = articles.filter(Boolean).length;
  return (
    <article ref={pieceRef} className={`dispatch-piece ${lead ? "dispatch-piece--lead" : ""}`} style={{ ["--today-theme" as string]: color, position: "relative" }} aria-busy={!written && isWriting}>
      <div className="dispatch-kicker">
        <span>{theme.kicker}</span>
        <span className="dispatch-kicker-count"> · {reports} {reports === 1 ? "report" : "reports"}</span>
      </div>
      <h3 className="dispatch-headline selectable-text">{theme.headline}</h3>
      {theme.dek && <p className="dispatch-dek selectable-text">{theme.dek}</p>}
      {lead && image && <img className="dispatch-image" src={image} alt="" loading="lazy" onError={(event) => { event.currentTarget.style.display = "none"; }} />}
      {written ? (
        <div className="dispatch-columns">
          <div className="dispatch-body selectable-text">
            {theme.body.map((paragraph, i) => <p key={i}><Cited text={paragraph} articles={articles} onOpen={onOpen} /></p>)}
          </div>
          {theme.takeaways.length > 0 && <aside className="dispatch-takeaways" aria-label="Takeaways">
            <h4>What it means</h4>
            <ul className="selectable-text">{theme.takeaways.map((line, i) => <li key={i}><Cited text={line} articles={articles} onOpen={onOpen} /></li>)}</ul>
          </aside>}
        </div>
      ) : theme.error ? (
        <p className="dispatch-error">{theme.error}</p>
      ) : (
        <Bars widths={lead ? ["100%", "96%", "88%", "93%", "60%"] : ["100%", "92%", "70%"]} />
      )}
      <ol className="dispatch-sources" aria-label="The reporting">
        {articles.map((article, i) => article && (
          <li key={article.id}>
            <button type="button" onClick={() => onOpen(article.id)} title={article.title}>
              <span className="dispatch-source-number">{i + 1}</span>
              <span className="dispatch-source-publication">{article.publication}</span>
              <span className="dispatch-source-title">{article.title}</span>
            </button>
          </li>
        ))}
      </ol>
      {written && <button type="button" className="today-story-control dispatch-ask" onClick={onAsk}><ChatIcon size={14} /> Ask about this</button>}
      {written && <ReaderSelectionAsk containerRef={pieceRef} onAsk={onAskAbout} />}
    </article>
  );
}

export function DispatchPane() {
  const { isPhone, sidebarCollapsed, selectedArticleId, openArticleFromToday, setPhonePane, todayPage, setTodayPage } = useUiStore();
  const { edition, standIn, window: win, days, isLoading, progress, error, retry, rewrite } = useDispatch();
  const { data: settings } = useSettings();
  const updateSettings = useUpdateSettings();
  const refreshFeeds = useRefreshAllFeeds();
  const agentContext = useAgentContext();
  const scrollRef = useRef<HTMLDivElement>(null);
  const isFrontPage = !isPhone && !selectedArticleId;
  const themes = edition?.themes ?? [];
  const isWriting = !!progress;
  // Until the new edition's lead is in, the page shows the edition before.
  const shown = themes.length > 0 ? edition : standIn;
  const shownThemes = shown?.themes ?? [];
  const lead = shownThemes[0];
  const leadImageQuery = useQuery({
    queryKey: ["dispatchImage", lead?.article_ids.join(",")],
    queryFn: () => commands.getTodayStoryImage(lead!.article_ids),
    enabled: !!lead,
    staleTime: Infinity,
  });
  const leadImage = leadImageQuery.data
    ?? shown?.articles.find((article) => lead?.article_ids.includes(article.id) && article.image_url)?.image_url;
  const failed = themes.filter((theme) => !theme.body.length && theme.error).length;

  const turnTo = (page: number) => {
    if (page < 1 || page > TODAY_PAGE_COUNT || page === todayPage) return;
    setTodayPage(page);
    scrollRef.current?.scrollTo?.({ top: 0, behavior: "instant" });
  };
  useEffect(() => {
    if (!isFrontPage) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.metaKey || event.ctrlKey || event.altKey) return;
      const target = event.target as HTMLElement | null;
      if (target && (target.closest("input, textarea, select, [contenteditable]") || target.closest('[role="dialog"]'))) return;
      if (event.key === "ArrowRight" && todayPage < TODAY_PAGE_COUNT) { event.preventDefault(); turnTo(todayPage + 1); }
      if (event.key === "ArrowLeft" && todayPage > 1) { event.preventDefault(); turnTo(todayPage - 1); }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }); // eslint-disable-line react-hooks/exhaustive-deps

  const setDays = (value: number) => {
    if (!settings || value === days) return;
    updateSettings.mutate({ ...settings, sync: { ...settings.sync, dispatch_days: value } });
  };
  const pageContext = { ...agentContext, page_stories: themes.map(themeForAgent), story: null };

  return (
    <div
      className={`today-page dispatch-page ${!isPhone ? "border-r border-white/5" : ""} bg-bg-secondary/70 flex flex-col h-full overflow-hidden`}
      style={{ width: isPhone || isFrontPage ? "100%" : 420, minWidth: isPhone ? "100%" : isFrontPage ? 0 : 360, flex: isFrontPage ? 1 : undefined }}
    >
      {sidebarCollapsed && !isPhone && <CollapsedSidebarTitlebar />}
      <div className="today-topbar flex flex-shrink-0 items-center gap-1 relative z-20" style={{ paddingLeft: 8, paddingRight: isPhone ? 8 : 20 }}>
        {isPhone && (
          <button onClick={() => setPhonePane("sidebar")} className="tap-target text-text-muted hover:text-text-primary transition-colors rounded-lg hover:bg-white/10" title="Open sidebar">
            <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
              <line x1="3" y1="6" x2="21" y2="6" /><line x1="3" y1="12" x2="21" y2="12" /><line x1="3" y1="18" x2="21" y2="18" />
            </svg>
          </button>
        )}
        <div className="flex-1" />
        {themes.length > 0 && <IconButton label={`Ask about ${PAPER_NAME}`} onClick={() => openAgentChat({ context: pageContext })} className="text-text-secondary hover:text-text-primary hover:bg-white/10">
          <ChatIcon size={18} />
        </IconButton>}
        <IconButton label={refreshFeeds.isPending ? "Refreshing…" : "Refresh feeds"} disabled={refreshFeeds.isPending} onClick={() => refreshFeeds.mutate(undefined)} className="text-text-secondary hover:text-text-primary hover:bg-white/10">
          <RefreshIcon size={18} className={refreshFeeds.isPending ? "smooth-spin" : undefined} />
        </IconButton>
        <SettingsCog label={`${PAPER_NAME} settings`} heading={PAPER_NAME} className="text-text-secondary">
          {(close) => (
            <>
              <div className="today-settings-row">
                <span>Covers</span>
                <div className="dispatch-days" role="radiogroup" aria-label="Days each edition covers">
                  {DISPATCH_DAY_CHOICES.map((choice) => (
                    <button key={choice} role="radio" aria-checked={days === choice} onClick={() => setDays(choice)}>{choice === 1 ? "1 day" : `${choice} days`}</button>
                  ))}
                </div>
              </div>
              <div className="today-settings-row">
                <span>Writing model</span>
                <ModelPicker surface="today" compact />
              </div>
              <button className="today-settings-row" disabled={isWriting} onClick={() => { close(); rewrite(); }}>Write a new edition</button>
              <hr />
              <button className="today-settings-row" onClick={() => { close(); openAiSettings(); }}>AI settings…</button>
            </>
          )}
        </SettingsCog>
      </div>

      <div ref={scrollRef} className="today-scroll flex-1 overflow-y-auto">
        <div className="today-content">
          <div className="today-masthead">
            <h2 className="today-title text-text-primary truncate">{PAPER_NAME}</h2>
            <div className="today-dateline">
              <span>{formatWindowDate(win)}</span>
              {edition && edition.article_count > 0 && (
                <span className="today-dateline-status">
                  Written by AI from {edition.article_count} articles{themes.length > 0 && <> · {themes.length} {themes.length === 1 ? "theme" : "themes"}</>}
                </span>
              )}
              <span className="today-dateline-progress"><span>{spanLabel(days, todayPage)}</span></span>
            </div>
            <div className="today-dateline-rule" role="presentation" />
          </div>

          {isWriting && <div className="dispatch-progress" role="status">
            <span>{progress}</span>
            <div className="story-rule-live" />
          </div>}

          {error && !isWriting && (
            <div role="alert" className="dispatch-notice">
              <AiErrorText error={`Couldn't write this edition: ${error}`} style={{ fontSize: 13 }} />
              <button className="today-story-control" onClick={retry}>Try again</button>
              <button className="today-story-control" onClick={openAiSettings}>AI settings</button>
            </div>
          )}

          {edition && !isWriting && edition.new_article_count > 0 && edition.themes.length > 0 && todayPage === 1 && (
            <div className="dispatch-notice">
              <span>{edition.new_article_count} new {edition.new_article_count === 1 ? "article" : "articles"} since this edition was written.</span>
              <button className="today-story-control" onClick={rewrite}>Write a new edition</button>
            </div>
          )}
          {!isWriting && failed > 0 && (
            <div className="dispatch-notice">
              <span>{failed} {failed === 1 ? "piece wasn't" : "pieces weren't"} written.</span>
              <button className="today-story-control" onClick={retry}>Retry</button>
            </div>
          )}
          {refreshFeeds.isError && <p role="alert" className="text-danger" style={{ fontSize: 13 }}>Could not refresh feeds. Please try again.</p>}

          {(isLoading || (isWriting && themes.length === 0)) && !standIn && (
            <div className="dispatch-front" aria-label={`Writing ${PAPER_NAME}`} aria-busy="true">
              <div className="dispatch-piece dispatch-piece--lead today-story-skeleton">
                <Bars widths={["18%"]} />
                <div className="today-story-skeleton-headline"><Bars widths={["90%", "72%"]} /></div>
                <Bars widths={["100%", "96%", "88%", "93%", "60%"]} />
              </div>
              <div className="dispatch-grid">
                {[0, 1, 2, 3].map((i) => <div key={i} className="dispatch-piece today-story-skeleton"><Bars widths={["24%", "88%", "100%", "94%", "70%"]} /></div>)}
              </div>
            </div>
          )}

          {!isLoading && !isWriting && edition?.status === "complete" && themes.length === 0 && (
            <div className="dispatch-empty">
              <p>{todayPage > 1 ? "Nothing was published in these days." : "Nothing to write about yet."}</p>
              <p>Refresh your feeds to bring in new articles.</p>
            </div>
          )}

          {shown && !themes.length && (
            <p className="dispatch-progress">Showing the edition for {formatWindowDate({ startsAt: shown.starts_at, endsAt: shown.ends_at })} while this one is written.</p>
          )}
          {shown && shownThemes.length > 0 && (
            <div className="dispatch-front">
              <Piece theme={shownThemes[0]} index={0} edition={shown} isWriting={isWriting} image={leadImage}
                onOpen={openArticleFromToday}
                onAsk={() => openAgentChat({ context: { ...pageContext, story: themeForAgent(shownThemes[0], 0) } })}
                onAskAbout={(text) => openAgentChat({ context: { ...pageContext, story: themeForAgent(shownThemes[0], 0) }, reply: { role: "story", text } })} />
              {shownThemes.length > 1 && <div className="dispatch-grid">
                {shownThemes.slice(1).map((theme, i) => (
                  <Piece key={`${i + 1}-${theme.headline}`} theme={theme} index={i + 1} edition={shown} isWriting={isWriting}
                    onOpen={openArticleFromToday}
                    onAsk={() => openAgentChat({ context: { ...pageContext, story: themeForAgent(theme, i + 1) } })}
                    onAskAbout={(text) => openAgentChat({ context: { ...pageContext, story: themeForAgent(theme, i + 1) }, reply: { role: "story", text } })} />
                ))}
              </div>}
              {shown.briefs.length > 0 && (
                <section className="dispatch-briefs" aria-label="Also in your feeds">
                  <h4 className="today-briefs-label">Also in your feeds</h4>
                  <ul>
                    {shown.briefs.map((brief, i) => {
                      const article = shown.articles.find((candidate) => candidate.id === brief.article_ids[0]);
                      return <li key={i}>
                        <span className="selectable-text">{brief.text}</span>
                        {article && <button type="button" className="dispatch-brief-source" onClick={() => openArticleFromToday(article.id)}>{article.publication}</button>}
                      </li>;
                    })}
                  </ul>
                </section>
              )}
              <p className="dispatch-colophon">
                Written by AI from your feeds{shown.model ? ` (${shown.model})` : ""}. It can get things wrong: the numbers link to the reporting.
              </p>
            </div>
          )}
        </div>
      </div>
      <nav className="today-pagination" aria-label="Newspaper pages">
        <button className="today-story-control" disabled={todayPage <= 1} onClick={() => turnTo(todayPage - 1)}>Previous page</button>
        <div className="today-page-position">
          <span role="status" aria-live="polite">{todayPage === 1 ? "Front page" : `Page ${todayPage}`}<span className="text-text-muted"> · {formatWindowDate(win)}</span></span>
        </div>
        <button className="today-story-control" disabled={todayPage >= TODAY_PAGE_COUNT} onClick={() => turnTo(todayPage + 1)}>Next page</button>
      </nav>
    </div>
  );
}
