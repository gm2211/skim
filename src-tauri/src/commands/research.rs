//! Deep research: a slower, fuller answer to a question about a topic. It
//! reads the reader's own feeds first, works out what they leave open, fills
//! those gaps from the web, and writes a briefing that cites both.
//!
//! Unlike the quick agent, the steps are fixed (plan, search the library, read,
//! find gaps, search the web, read, write), so every provider follows the same
//! path and the reader can watch it happen.

use crate::ai::local_provider::SharedModelState;
use crate::ai::provider::{AiProvider, ChatMessage, ChatRequest};
use crate::commands::agent::{chat_provider, AgentContext, AgentResponse, AgentStep};
use crate::commands::ai::extract_json_object;
use crate::commands::chat::{
    publication_context, query_excerpt, query_keywords, retrieve_chat_articles_for_terms, run_web_search,
    ChatMessageInput, ChatSource, SearchResult,
};
use crate::db::models::ArticleWithFeed;
use crate::db::{queries, Database};
use crate::AppHandle;
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::time::Duration;
use tauri::{Emitter, State};

pub const RESEARCH_PROGRESS_EVENT: &str = "research-progress";

/// Articles from the library the briefing may cite.
const LIBRARY_ARTICLES: usize = 14;
/// Of those, how many are read in full rather than from their feed text.
const READ_ARTICLES: usize = 8;
const LIBRARY_QUERIES: usize = 5;
const WEB_QUERIES: usize = 3;
const WEB_RESULTS_PER_QUERY: usize = 5;
/// Web results whose pages are read, beyond their search snippet.
const WEB_PAGES_READ: usize = 4;
const WEB_PAGE_TIMEOUT: Duration = Duration::from_secs(12);
const BRIEFING_TOKENS: i64 = 3000;

#[derive(Debug, Clone, Serialize)]
pub struct ResearchProgress {
    pub request_id: String,
    pub label: String,
}

/// Where research looks things up. The app's is the library database and the
/// web; tests script one.
#[async_trait]
pub trait ResearchTools: Send + Sync {
    /// Library articles matching `terms`, best first.
    async fn search_library(&self, terms: &[String]) -> Result<Vec<ArticleWithFeed>, String>;
    /// The fullest text of each article, in order.
    async fn read_articles(&self, articles: &[ArticleWithFeed]) -> Vec<String>;
    async fn web_search(&self, query: &str) -> Result<Vec<SearchResult>, String>;
    async fn read_page(&self, url: &str) -> Result<String, String>;
}

#[derive(Debug, Default, Deserialize)]
struct Plan {
    #[serde(default)]
    topic: String,
    #[serde(default)]
    library_queries: Vec<String>,
}

#[derive(Debug, Default, Deserialize)]
struct Gaps {
    #[serde(default)]
    gaps: Vec<String>,
    #[serde(default)]
    web_queries: Vec<String>,
}

/// A web source the briefing can cite as [wN].
#[derive(Debug, Clone)]
struct WebSource {
    result: SearchResult,
    text: Option<String>,
}

/// What research found, ready to hand back as an agent answer.
pub struct Briefing {
    pub content: String,
    pub articles: Vec<ArticleWithFeed>,
    pub web: Vec<SearchResult>,
    pub steps: Vec<AgentStep>,
}

fn parse_json<T: for<'de> Deserialize<'de> + Default>(text: &str) -> T {
    extract_json_object(text).and_then(|json| serde_json::from_str(json).ok()).unwrap_or_default()
}

fn clean_queries(queries: Vec<String>, limit: usize) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for query in queries {
        let query = query.trim().trim_matches('"').trim().to_string();
        if !query.is_empty() && query.chars().count() <= 120 && !out.iter().any(|q| q.eq_ignore_ascii_case(&query)) {
            out.push(query);
        }
        if out.len() == limit {
            break;
        }
    }
    out
}

/// The site a web result came from, for the reader and the model.
fn domain(url: &str) -> String {
    let host = url.split("://").nth(1).unwrap_or(url).split('/').next().unwrap_or("");
    host.trim_start_matches("www.").to_string()
}

fn date_of(article: &ArticleWithFeed) -> String {
    article
        .article
        .published_at
        .and_then(|t| chrono::DateTime::from_timestamp(t, 0))
        .map(|d| d.format("%Y-%m-%d").to_string())
        .unwrap_or_else(|| "undated".into())
}

/// Merge several ranked searches: an article found by more of them, or nearer
/// the top of one, ranks higher (reciprocal rank fusion). Articles the reader
/// is already looking at come first.
fn fuse(pinned: Vec<ArticleWithFeed>, searches: Vec<Vec<ArticleWithFeed>>, limit: usize) -> Vec<ArticleWithFeed> {
    let mut scores: HashMap<String, f64> = HashMap::new();
    let mut first_seen: Vec<ArticleWithFeed> = Vec::new();
    for found in &searches {
        for (rank, article) in found.iter().enumerate() {
            let id = &article.article.id;
            if !scores.contains_key(id) {
                first_seen.push(article.clone());
            }
            *scores.entry(id.clone()).or_default() += 1.0 / (rank as f64 + 4.0);
        }
    }
    first_seen.sort_by(|a, b| {
        scores[&b.article.id].partial_cmp(&scores[&a.article.id]).unwrap_or(std::cmp::Ordering::Equal)
    });
    let mut out: Vec<ArticleWithFeed> = Vec::new();
    for article in pinned.into_iter().chain(first_seen) {
        if !out.iter().any(|a| a.article.id == article.article.id) {
            out.push(article);
        }
        if out.len() == limit {
            break;
        }
    }
    out
}

fn library_block(articles: &[ArticleWithFeed], texts: &[String], question: &str) -> String {
    if articles.is_empty() {
        return "The reader's articles have nothing on this.".into();
    }
    articles
        .iter()
        .enumerate()
        .map(|(i, article)| {
            let text = texts.get(i).cloned().unwrap_or_else(|| crate::commands::article_body::feed_body_text(&article.article));
            let excerpt = query_excerpt(&text, question, if i < READ_ARTICLES { 2500 } else { 600 });
            format!(
                "[{}] {} ({}, {})\n{}\nURL: {}\n{}",
                i + 1,
                article.article.title,
                article.feed_title,
                date_of(article),
                publication_context(article.article.published_at),
                article.article.url.as_deref().unwrap_or(""),
                if excerpt.trim().is_empty() { "(no text available)".into() } else { excerpt },
            )
        })
        .collect::<Vec<_>>()
        .join("\n\n")
}

fn web_block(web: &[WebSource], question: &str) -> String {
    web.iter()
        .enumerate()
        .map(|(i, source)| {
            let body = source
                .text
                .as_deref()
                .map(|text| query_excerpt(text, question, 1800))
                .filter(|text| !text.trim().is_empty())
                .unwrap_or_else(|| source.result.snippet.clone());
            format!("[w{}] {} ({})\nURL: {}\n{}", i + 1, source.result.title, domain(&source.result.url), source.result.url, body)
        })
        .collect::<Vec<_>>()
        .join("\n\n")
}

const PLAN_PROMPT: &str = "You plan research in a reader's RSS library. Given their question, name the topic and write keyword searches that would find articles about it: the main names and terms, synonyms, and closely related angles. Each search is 1 to 4 words, not a sentence. Reply with JSON only: {\"topic\": \"the topic in a few words\", \"library_queries\": [\"...\", \"...\"]} with 3 to 5 searches.";

const GAPS_PROMPT: &str = "You review what a reader's own articles say about their question and decide what a complete briefing still needs from the web: background they assume, developments newer than the newest article, missing perspectives, figures or primary sources. Ignore gaps that do not matter to the question. Reply with JSON only: {\"gaps\": [\"short phrase\", ...], \"web_queries\": [\"web search query\", ...]} with at most 3 web queries, each a plain search-engine query. If the articles cover the question well, still give 1 query that checks for the latest news. If there are no articles, plan queries that cover the whole question.";

fn briefing_prompt(today: &str) -> String {
    format!(
        "You are Skim's research desk. Write a briefing that answers the reader's question in full, \
         from the sources below. Today is {today}.\n\n\
         Format, in Markdown:\n\
         - Open with a bottom line of 2 to 3 sentences that answers the question directly. No heading above it and no title.\n\
         - Then sections with ## headings. Pick the ones that fit, such as What's happening, Background, Key facts and figures, Where sources differ, What to watch.\n\
         - Short paragraphs and bullets. About 400 to 700 words in all.\n\n\
         Citations: put [n] right after each claim from the reader's articles and [wN] after each claim \
         from a web source, e.g. [2] or [w1]. Cite every factual claim. Lean on the reader's articles \
         first and use the web for what they lack. Where a point rests only on the web, the [wN] \
         citation shows it. Say plainly what remains unknown or disputed. Never invent sources, numbers \
         or quotes. No emoji. Do not list the sources at the end: Skim shows them as cards under the briefing."
    )
}

async fn ask(provider: &dyn AiProvider, model: &str, system: &str, user: String, max_tokens: i64, json: bool) -> Result<String, String> {
    let response = provider
        .chat(ChatRequest {
            model: model.to_string(),
            messages: vec![ChatMessage::text("system", system), ChatMessage::text("user", user)],
            temperature: Some(0.3),
            max_tokens: Some(max_tokens),
            json_mode: json,
            tools: None,
        })
        .await?;
    Ok(response.content)
}

/// Research `question` and write the briefing. `pinned` are articles the
/// reader has on screen (the open article, the focused story's reports).
pub async fn research(
    provider: &dyn AiProvider,
    model: &str,
    question: &str,
    history: &str,
    pinned: Vec<ArticleWithFeed>,
    tools: &dyn ResearchTools,
    progress: &(dyn Fn(&str) + Send + Sync),
) -> Result<Briefing, String> {
    let mut steps: Vec<AgentStep> = Vec::new();
    let step = |steps: &mut Vec<AgentStep>, tool: &str, label: String| {
        progress(&label);
        steps.push(AgentStep { tool: tool.into(), label });
    };
    let asked = if history.is_empty() { question.to_string() } else { format!("{history}\n\nQuestion: {question}") };

    // 1. Plan searches of the library.
    step(&mut steps, "plan", "Planning the research".into());
    // A provider that cannot answer at all fails here, before any searching.
    let plan: Plan = parse_json(&ask(provider, model, PLAN_PROMPT, asked.clone(), 400, true).await?);
    let mut library_queries = clean_queries(plan.library_queries, LIBRARY_QUERIES);
    if library_queries.is_empty() {
        library_queries.push(question.to_string());
    }
    let topic = if plan.topic.trim().is_empty() { question.to_string() } else { plan.topic.trim().to_string() };
    // Excerpts favour passages about the topic as well as the question's own words.
    let focus = format!("{question} {topic} {}", library_queries.join(" "));

    // 2. Search the library.
    let mut searches = Vec::new();
    for query in &library_queries {
        let terms = query_keywords(query);
        if terms.is_empty() {
            continue;
        }
        step(&mut steps, "search_articles", format!("Searched your feeds for \u{201c}{query}\u{201d}"));
        searches.push(tools.search_library(&terms).await?);
    }
    let articles = fuse(pinned, searches, LIBRARY_ARTICLES);

    // 3. Read the best of them in full.
    let read = articles.len().min(READ_ARTICLES);
    if read > 0 {
        step(&mut steps, "get_article", format!("Read {read} of your articles"));
    }
    let mut texts = tools.read_articles(&articles[..read]).await;
    texts.extend(articles[read..].iter().map(|a| crate::commands::article_body::feed_body_text(&a.article)));
    let library = library_block(&articles, &texts, &focus);

    // 4. Find what the library leaves open.
    step(&mut steps, "gaps", "Looked for gaps in your feeds' coverage".into());
    let gaps: Gaps = ask(
        provider,
        model,
        GAPS_PROMPT,
        format!("Question: {asked}\nTopic: {topic}\n\nThe reader's articles:\n{library}"),
        500,
        true,
    )
    .await
    .map(|text| parse_json(&text))
    .unwrap_or_default();
    let mut web_queries = clean_queries(gaps.web_queries, WEB_QUERIES);
    if web_queries.is_empty() {
        web_queries.push(topic.clone());
    }

    // 5. Fill the gaps from the web.
    let library_urls: Vec<&str> = articles.iter().filter_map(|a| a.article.url.as_deref()).collect();
    let mut web: Vec<WebSource> = Vec::new();
    let mut per_query: Vec<Vec<usize>> = Vec::new();
    for query in &web_queries {
        step(&mut steps, "web_search", format!("Searched the web for \u{201c}{query}\u{201d}"));
        let mut indices = Vec::new();
        match tools.web_search(query).await {
            Ok(results) => {
                for result in results.into_iter().take(WEB_RESULTS_PER_QUERY) {
                    if library_urls.contains(&result.url.as_str()) {
                        continue;
                    }
                    let index = match web.iter().position(|w| w.result.url == result.url) {
                        Some(index) => index,
                        None => {
                            web.push(WebSource { result, text: None });
                            web.len() - 1
                        }
                    };
                    indices.push(index);
                }
            }
            Err(error) => {
                let label = format!("Web search failed: {error}");
                step(&mut steps, "web_search_failed", label);
            }
        }
        per_query.push(indices);
    }

    // 6. Read the top web pages, taking each query's best result in turn.
    let mut to_read: Vec<usize> = Vec::new();
    for rank in 0..WEB_RESULTS_PER_QUERY {
        for indices in &per_query {
            if let Some(&index) = indices.get(rank) {
                if !to_read.contains(&index) && to_read.len() < WEB_PAGES_READ {
                    to_read.push(index);
                }
            }
        }
    }
    if !to_read.is_empty() {
        let mut sites: Vec<String> = Vec::new();
        for &i in &to_read {
            let site = domain(&web[i].result.url);
            if !sites.contains(&site) {
                sites.push(site);
            }
        }
        let pages = if to_read.len() == 1 { "1 web page".to_string() } else { format!("{} web pages", to_read.len()) };
        step(&mut steps, "read_web_page", format!("Read {pages} ({})", sites.join(", ")));
        let pages = futures_util::future::join_all(to_read.iter().map(|&i| {
            let url = web[i].result.url.clone();
            async move { tokio::time::timeout(WEB_PAGE_TIMEOUT, tools.read_page(&url)).await.ok().and_then(Result::ok) }
        }))
        .await;
        for (&index, page) in to_read.iter().zip(pages) {
            web[index].text = page.filter(|text| text.split_whitespace().count() >= 60);
        }
    }

    // 7. Write the briefing.
    step(&mut steps, "write", "Writing the briefing".into());
    let today = chrono::Local::now().format("%Y-%m-%d").to_string();
    let gaps_note = if gaps.gaps.is_empty() { String::new() } else { format!("\n\nGaps the web sources were found to fill: {}", gaps.gaps.join("; ")) };
    let web_text = if web.is_empty() { "None found.".to_string() } else { web_block(&web, &focus) };
    let content = ask(
        provider,
        model,
        &briefing_prompt(&today),
        format!(
            "Question: {asked}\n\nThe reader's articles (cite as [n]):\n{library}\n\nWeb sources (cite as [wN]):\n{web_text}{gaps_note}"
        ),
        BRIEFING_TOKENS,
        false,
    )
    .await?;
    let content = content.trim().to_string();
    if content.is_empty() {
        return Err("The model returned an empty briefing. Try again.".into());
    }

    Ok(Briefing { content, articles, web: web.into_iter().map(|w| w.result).collect(), steps })
}

struct AppResearchTools<'a> {
    db: &'a Database,
}

#[async_trait]
impl ResearchTools for AppResearchTools<'_> {
    async fn search_library(&self, terms: &[String]) -> Result<Vec<ArticleWithFeed>, String> {
        let conn = self.db.conn.lock().map_err(|e| e.to_string())?;
        retrieve_chat_articles_for_terms(&conn, "all", terms, false).map_err(|e| e.to_string())
    }

    async fn read_articles(&self, articles: &[ArticleWithFeed]) -> Vec<String> {
        let plain: Vec<_> = articles.iter().map(|a| a.article.clone()).collect();
        crate::commands::article_body::resolve_selected_article_texts(self.db, &plain).await
    }

    async fn web_search(&self, query: &str) -> Result<Vec<SearchResult>, String> {
        run_web_search(query, WEB_RESULTS_PER_QUERY).await
    }

    async fn read_page(&self, url: &str) -> Result<String, String> {
        let content = crate::commands::articles::fetch_article_content(url).await?;
        Ok(html2text::from_read(content.html.as_bytes(), 10_000))
    }
}

/// The articles the reader has on screen, so research starts from them.
fn pinned_articles(db: &Database, context: &AgentContext) -> Result<Vec<ArticleWithFeed>, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    let mut ids: Vec<&String> = context.article_id.iter().collect();
    if let Some(story) = &context.story {
        ids.extend(story.article_ids.iter().take(4));
    }
    let mut out = Vec::new();
    for id in ids {
        if let Some(article) = queries::get_article_by_id(&conn, id).map_err(|e| e.to_string())? {
            out.push(article);
        }
    }
    Ok(out)
}

/// Turn a briefing into the agent's answer shape: articles first (cited [n]
/// by position), then web results (cited [wN] by their order).
pub fn briefing_response(briefing: Briefing, provider: String, model: String) -> AgentResponse {
    let mut sources: Vec<ChatSource> = briefing
        .articles
        .iter()
        .map(|a| ChatSource {
            id: a.article.id.clone(),
            title: a.article.title.clone(),
            feed_title: a.feed_title.clone(),
            url: a.article.url.clone(),
            published_at: a.article.published_at,
            source_type: "article".into(),
        })
        .collect();
    for (index, result) in briefing.web.iter().enumerate() {
        sources.push(ChatSource {
            id: format!("web-{index}"),
            title: result.title.clone(),
            feed_title: domain(&result.url),
            url: Some(result.url.clone()),
            published_at: None,
            source_type: "web".into(),
        });
    }
    AgentResponse {
        content: briefing.content,
        provider,
        model,
        article_ids: briefing.articles.iter().map(|a| a.article.id.clone()).collect(),
        sources,
        actions: Vec::new(),
        steps: briefing.steps,
    }
}

/// Deep research on a topic: the reader's feeds, then the web, then a cited
/// briefing. Progress goes out as `research-progress` events tagged with
/// `request_id`.
#[tauri::command]
pub async fn research_topic(
    app: AppHandle,
    db: State<'_, Database>,
    model_state: State<'_, SharedModelState>,
    messages: Vec<ChatMessageInput>,
    context: Option<AgentContext>,
    request_id: String,
) -> Result<AgentResponse, String> {
    let question = messages
        .iter()
        .rev()
        .find(|m| m.role == "user")
        .map(|m| m.content.trim().to_string())
        .filter(|q| !q.is_empty())
        .ok_or("Question cannot be empty")?;
    // Earlier turns, so a follow-up such as "go deeper on the second point" has its referent.
    let history = messages
        .iter()
        .take(messages.len().saturating_sub(1))
        .filter(|m| m.role == "user" || m.role == "assistant")
        .map(|m| format!("{}: {}", if m.role == "user" { "Reader" } else { "Skim" }, m.content.chars().take(1500).collect::<String>()))
        .collect::<Vec<_>>();
    let history = if history.is_empty() { String::new() } else { format!("Conversation so far:\n{}", history.join("\n")) };
    let context = context.unwrap_or_default();
    let (provider, model) = chat_provider(&app, db.inner(), model_state.inner())?;
    let pinned = pinned_articles(&db, &context)?;
    let tools = AppResearchTools { db: db.inner() };
    let progress = |label: &str| {
        let _ = app.emit(RESEARCH_PROGRESS_EVENT, ResearchProgress { request_id: request_id.clone(), label: label.to_string() });
    };
    let briefing = research(provider.as_ref(), &model, &question, &history, pinned, &tools, &progress).await?;
    Ok(briefing_response(briefing, provider.name().to_string(), model))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ai::provider::ChatResponse as ProviderChatResponse;
    use crate::db::models::Article;
    use std::sync::Mutex;

    struct Scripted {
        replies: Mutex<Vec<String>>,
        seen: Mutex<Vec<ChatRequest>>,
    }

    impl Scripted {
        fn new(replies: &[&str]) -> Self {
            Self { replies: Mutex::new(replies.iter().rev().map(|r| r.to_string()).collect()), seen: Mutex::new(Vec::new()) }
        }
    }

    #[async_trait]
    impl AiProvider for Scripted {
        async fn chat(&self, request: ChatRequest) -> Result<ProviderChatResponse, String> {
            self.seen.lock().unwrap().push(request);
            let content = self.replies.lock().unwrap().pop().unwrap_or_default();
            Ok(ProviderChatResponse { content, model: "m".into(), usage: None, tool_uses: Vec::new(), stop_reason: None, raw_content: None })
        }
        fn name(&self) -> &str { "scripted" }
    }

    fn article(id: &str, title: &str, url: &str) -> ArticleWithFeed {
        ArticleWithFeed {
            article: Article {
                id: id.into(),
                feed_id: "f".into(),
                title: title.into(),
                url: Some(url.into()),
                author: None,
                content_html: None,
                content_text: Some(format!("{title} body text")),
                published_at: Some(1_760_000_000),
                fetched_at: 0,
                is_read: false,
                is_starred: false,
                feedly_entry_id: None,
                comments_url: None,
            },
            feed_title: "The Verge".into(),
            feed_icon_url: None,
        }
    }

    #[derive(Default)]
    struct Stub {
        searched: Mutex<Vec<Vec<String>>>,
        web_queries: Mutex<Vec<String>>,
        pages: Mutex<Vec<String>>,
        web_fails: bool,
    }

    #[async_trait]
    impl ResearchTools for Stub {
        async fn search_library(&self, terms: &[String]) -> Result<Vec<ArticleWithFeed>, String> {
            self.searched.lock().unwrap().push(terms.to_vec());
            Ok(match terms.first().map(String::as_str) {
                Some("fusion") => vec![article("a1", "Fusion startup hits milestone", "https://a.test/1"), article("a2", "Why fusion is always 30 years away", "https://a.test/2")],
                Some("iter") => vec![article("a2", "Why fusion is always 30 years away", "https://a.test/2"), article("a3", "ITER delays again", "https://a.test/3")],
                _ => Vec::new(),
            })
        }
        async fn read_articles(&self, articles: &[ArticleWithFeed]) -> Vec<String> {
            articles.iter().map(|a| format!("{} full text", a.article.title)).collect()
        }
        async fn web_search(&self, query: &str) -> Result<Vec<SearchResult>, String> {
            self.web_queries.lock().unwrap().push(query.into());
            if self.web_fails {
                return Err("DuckDuckGo blocked the search".into());
            }
            Ok(vec![
                SearchResult { title: "ITER official timeline".into(), url: "https://www.iter.org/timeline".into(), snippet: "First plasma 2034".into() },
                SearchResult { title: "Duplicate of a library article".into(), url: "https://a.test/3".into(), snippet: "dup".into() },
            ])
        }
        async fn read_page(&self, url: &str) -> Result<String, String> {
            self.pages.lock().unwrap().push(url.into());
            Ok("word ".repeat(80))
        }
    }

    const PLAN: &str = "{\"topic\": \"Fusion power\", \"library_queries\": [\"fusion\", \"ITER\", \"fusion\"]}";
    const GAPS: &str = "Here you go: {\"gaps\": [\"ITER schedule\"], \"web_queries\": [\"ITER first plasma date\", \"fusion news\"]}";

    #[tokio::test]
    async fn reads_the_feeds_then_fills_gaps_from_the_web() {
        let provider = Scripted::new(&[PLAN, GAPS, "Fusion is close but not here [1][w1].\n\n## What's happening\nITER slips [3]."]);
        let tools = Stub::default();
        let labels = Mutex::new(Vec::new());
        let progress = |label: &str| labels.lock().unwrap().push(label.to_string());
        let briefing = research(&provider, "m", "Where is fusion power at?", "", Vec::new(), &tools, &progress).await.unwrap();

        // Duplicate planned searches run once; results are fused across them.
        assert_eq!(*tools.searched.lock().unwrap(), vec![vec!["fusion".to_string()], vec!["iter".to_string()]]);
        let ids: Vec<_> = briefing.articles.iter().map(|a| a.article.id.as_str()).collect();
        assert_eq!(ids, vec!["a2", "a1", "a3"], "found by both searches ranks first");
        assert_eq!(*tools.web_queries.lock().unwrap(), vec!["ITER first plasma date", "fusion news"]);
        // A web result that is already one of the reader's articles is not cited twice.
        assert_eq!(briefing.web.len(), 1);
        assert_eq!(*tools.pages.lock().unwrap(), vec!["https://www.iter.org/timeline"]);
        assert!(briefing.content.starts_with("Fusion is close"));

        let seen = provider.seen.lock().unwrap();
        assert_eq!(seen.len(), 3);
        assert!(seen[0].json_mode && seen[1].json_mode && !seen[2].json_mode);
        let writer = &seen[2].messages[1].content;
        assert!(writer.contains("[1] Why fusion is always 30 years away (The Verge"), "{writer}");
        assert!(writer.contains("full text"), "read articles use their full text: {writer}");
        assert!(writer.contains("[w1] ITER official timeline (iter.org)"), "{writer}");
        assert!(writer.contains("Gaps the web sources were found to fill: ITER schedule"), "{writer}");

        let labels = labels.lock().unwrap();
        assert_eq!(labels.first().unwrap(), "Planning the research");
        assert!(labels.contains(&"Searched your feeds for \u{201c}ITER\u{201d}".to_string()));
        assert!(labels.contains(&"Read 3 of your articles".to_string()));
        assert!(labels.contains(&"Read 1 web page (iter.org)".to_string()));
        assert_eq!(labels.last().unwrap(), "Writing the briefing");
        assert_eq!(briefing.steps.len(), labels.len());
    }

    #[tokio::test]
    async fn a_failed_web_search_still_writes_from_the_feeds() {
        let provider = Scripted::new(&[PLAN, GAPS, "From your feeds only [1]."]);
        let tools = Stub { web_fails: true, ..Default::default() };
        let briefing = research(&provider, "m", "fusion?", "", Vec::new(), &tools, &|_| {}).await.unwrap();
        assert!(briefing.web.is_empty());
        assert!(briefing.steps.iter().any(|s| s.label.starts_with("Web search failed")));
        assert!(provider.seen.lock().unwrap()[2].messages[1].content.contains("Web sources (cite as [wN]):\nNone found."));
    }

    #[tokio::test]
    async fn unparseable_plans_fall_back_to_the_question_and_topic() {
        let provider = Scripted::new(&["sure!", "no json", "Briefing [w1]."]);
        let tools = Stub::default();
        let pinned = vec![article("open", "The article on screen", "https://a.test/open")];
        let briefing = research(&provider, "m", "fusion reactors", "", pinned, &tools, &|_| {}).await.unwrap();
        assert_eq!(*tools.searched.lock().unwrap(), vec![vec!["fusion".to_string(), "reactors".to_string()]]);
        assert_eq!(briefing.articles[0].article.id, "open", "what the reader is looking at comes first");
        assert_eq!(*tools.web_queries.lock().unwrap(), vec!["fusion reactors"]);
    }

    #[test]
    fn responses_number_articles_then_web_sources() {
        let briefing = Briefing {
            content: "x".into(),
            articles: vec![article("a1", "One", "https://a.test/1")],
            web: vec![SearchResult { title: "W".into(), url: "https://www.example.com/page".into(), snippet: String::new() }],
            steps: Vec::new(),
        };
        let response = briefing_response(briefing, "p".into(), "m".into());
        assert_eq!(response.sources.len(), 2);
        assert_eq!(response.sources[1].source_type, "web");
        assert_eq!(response.sources[1].feed_title, "example.com");
        assert_eq!(response.article_ids, vec!["a1"]);
    }
}
