//! Skim's app agent: one chat backend that can use the app's own tools
//! (search the library, read an article, open one) and knows what the user is
//! looking at. The command palette falls back to it, and the full Ask Skim
//! chat continues the same conversation.
//!
//! Tool calls use a plain-text protocol instead of a provider's native
//! tool-use API, so the agent works the same with every configured provider:
//! hosted APIs, subscriptions, the Claude CLI and local models alike.

use crate::ai::local_provider::SharedModelState;
use crate::ai::provider::{create_provider_with_app, AiProvider, ChatMessage, ChatRequest};
use crate::commands::chat::{
    publication_context, query_excerpt, query_keywords, resolve_chat_settings,
    retrieve_chat_articles_for_terms, run_web_search, ChatMessageInput, ChatSource, WebCitation,
};
use crate::db::models::ArticleWithFeed;
use crate::db::{queries, Database};
use crate::AppHandle;
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use tauri::State;

/// Model turns per question. The last one is told to answer without tools.
const MAX_ROUNDS: usize = 6;
/// Tool calls honoured from a single model turn.
const MAX_CALLS_PER_ROUND: usize = 3;
/// Articles numbered for citation in one conversation.
const MAX_SOURCES: usize = 40;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct AgentStory {
    pub story_id: String,
    pub title: String,
    #[serde(default)]
    pub summary: Option<String>,
    #[serde(default)]
    pub article_ids: Vec<String>,
}

/// What the user is looking at when they ask. Every field is optional so a
/// caller can say as much or as little as it knows.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct AgentContext {
    /// "today", "catchup", "inbox", "all", "feed", "folder", "starred", ...
    #[serde(default)]
    pub view: Option<String>,
    /// Human name of the view, e.g. a feed or folder title.
    #[serde(default)]
    pub view_label: Option<String>,
    /// The article open in the reader, if any.
    #[serde(default)]
    pub article_id: Option<String>,
    /// The story the user is focused on (Today), if any.
    #[serde(default)]
    pub story: Option<AgentStory>,
    /// The stories printed on the page (Today), in page order.
    #[serde(default)]
    pub page_stories: Vec<AgentStory>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AgentAction {
    #[serde(rename = "type")]
    pub kind: String,
    pub article_id: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct AgentStep {
    pub tool: String,
    pub label: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct AgentResponse {
    pub content: String,
    pub provider: String,
    pub model: String,
    /// Article sources first (cited as [n] by position), then web results.
    pub sources: Vec<ChatSource>,
    /// The numbered article ids, to pass back on the next turn so citation
    /// numbers stay stable across the conversation.
    pub article_ids: Vec<String>,
    /// UI actions the agent asked for, such as opening an article.
    pub actions: Vec<AgentAction>,
    /// The tools the agent used, for showing what it did.
    pub steps: Vec<AgentStep>,
}

/// One parsed tool call from a model turn.
#[derive(Debug, Clone, PartialEq)]
pub struct ToolCall {
    pub name: String,
    pub input: serde_json::Value,
}

/// Find `TOOL {"name": ..., "input": {...}}` lines in a model turn. Tolerates
/// code fences, a missing `input`, and inputs written inline beside `name`.
pub fn parse_tool_calls(text: &str) -> Vec<ToolCall> {
    let mut calls = Vec::new();
    for line in text.lines() {
        let line = line.trim().trim_matches('`').trim();
        let Some(rest) = line.strip_prefix("TOOL") else { continue };
        let rest = rest.trim_start_matches(':').trim();
        let Ok(value) = serde_json::from_str::<serde_json::Value>(rest) else { continue };
        let Some(name) = value.get("name").and_then(|n| n.as_str()) else { continue };
        let input = match value.get("input") {
            Some(input) if input.is_object() => input.clone(),
            _ => {
                let mut inline = value.clone();
                if let Some(map) = inline.as_object_mut() {
                    map.remove("name");
                }
                inline
            }
        };
        calls.push(ToolCall { name: name.to_string(), input });
        if calls.len() == MAX_CALLS_PER_ROUND {
            break;
        }
    }
    calls
}

/// Remove tool-call lines from text the user will see.
fn strip_tool_lines(text: &str) -> String {
    text.lines()
        .filter(|line| !line.trim().trim_matches('`').trim().starts_with("TOOL"))
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string()
}

#[async_trait]
pub trait AgentTools: Send {
    /// Run one tool and return the text the model reads back.
    async fn call(&mut self, call: &ToolCall) -> Result<String, String>;
}

const TOOL_GUIDE: &str = "Tools (call one by replying with a line `TOOL {\"name\": ..., \"input\": {...}}` and nothing else; you will get a RESULT message back):
- search_articles {\"query\": string, \"scope\": \"all\"|\"unread\"|\"starred\" (default \"all\"), \"limit\": 1-10}: keyword search over the user's articles (titles, sources, URLs, text). Use a few distinctive topic words, not a sentence. If nothing matches, try synonyms or fewer words.
- recent_articles {\"scope\": \"all\"|\"unread\"|\"starred\"}: the newest articles.
- get_article {\"ref\": number}: read an article's text by its [n] number.
- open_article {\"ref\": number}: open the article in the reader. Only when the user asks to open, show or read a specific article.
- web_search {\"query\": string}: search the public web, only when the user's articles cannot answer.";

pub fn system_prompt(context_block: &str) -> String {
    format!(
        "You are Skim's assistant, inside an RSS reader. You can use tools to search and read the \
         user's articles and to open one for them. Prefer the user's own articles as evidence and \
         cite them with their bracket number like [2]. When the user is looking for an article, \
         search, then list the best matches as short bullets, each starting with its [n] number and \
         title. If nothing matches, say so plainly. Be concise. No emoji. Never invent articles or \
         numbers.\n\n{TOOL_GUIDE}\n\n{context_block}"
    )
}

/// Run the model, executing its tool calls, until it answers in prose.
pub async fn run_agent_loop(
    provider: &dyn AiProvider,
    model: &str,
    mut messages: Vec<ChatMessage>,
    tools: &mut dyn AgentTools,
) -> Result<String, String> {
    for round in 0..MAX_ROUNDS {
        let last = round + 1 == MAX_ROUNDS;
        if last {
            messages.push(ChatMessage::text(
                "user",
                "RESULT: tool budget used up. Answer now from what you have, without TOOL lines.",
            ));
        }
        let response = provider
            .chat(ChatRequest {
                model: model.to_string(),
                messages: messages.clone(),
                temperature: Some(0.3),
                max_tokens: Some(1500),
                json_mode: false,
                tools: None,
            })
            .await?;
        let calls = if last { Vec::new() } else { parse_tool_calls(&response.content) };
        if calls.is_empty() {
            let answer = strip_tool_lines(&response.content);
            return Ok(if answer.is_empty() { "I couldn't find an answer to that.".into() } else { answer });
        }
        messages.push(ChatMessage::text("assistant", response.content.clone()));
        let mut results = Vec::new();
        for call in &calls {
            let result = match tools.call(call).await {
                Ok(text) => text,
                Err(error) => format!("error: {error}"),
            };
            results.push(format!("RESULT {}:\n{}", call.name, result));
        }
        messages.push(ChatMessage::text("user", results.join("\n\n")));
    }
    unreachable!("the last round always answers")
}

/// The app's tools, backed by the library database.
struct LibraryTools<'a> {
    db: &'a Database,
    question: String,
    sources: Vec<ArticleWithFeed>,
    web: Vec<WebCitation>,
    actions: Vec<AgentAction>,
    steps: Vec<AgentStep>,
}

impl<'a> LibraryTools<'a> {
    fn new(db: &'a Database, question: &str) -> Self {
        Self { db, question: question.to_string(), sources: Vec::new(), web: Vec::new(), actions: Vec::new(), steps: Vec::new() }
    }

    /// The article's citation number, numbering it if it is new.
    fn number(&mut self, article: &ArticleWithFeed) -> Option<usize> {
        if let Some(index) = self.sources.iter().position(|s| s.article.id == article.article.id) {
            return Some(index + 1);
        }
        if self.sources.len() >= MAX_SOURCES {
            return None;
        }
        self.sources.push(article.clone());
        Some(self.sources.len())
    }

    fn load(&self, id: &str) -> Result<Option<ArticleWithFeed>, String> {
        let conn = self.db.conn.lock().map_err(|e| e.to_string())?;
        queries::get_article_by_id(&conn, id).map_err(|e| e.to_string())
    }

    fn number_id(&mut self, id: &str) -> Result<Option<(usize, ArticleWithFeed)>, String> {
        let Some(article) = self.load(id)? else { return Ok(None) };
        Ok(self.number(&article).map(|n| (n, article)))
    }

    fn by_ref(&self, input: &serde_json::Value) -> Result<ArticleWithFeed, String> {
        let reference = input.get("ref").or_else(|| input.get("id"));
        let index = match reference {
            Some(serde_json::Value::Number(n)) => n.as_u64().map(|n| n as usize),
            Some(serde_json::Value::String(s)) => s.trim().trim_matches(|c| c == '[' || c == ']').parse().ok(),
            _ => None,
        };
        index
            .and_then(|n| n.checked_sub(1))
            .and_then(|i| self.sources.get(i))
            .cloned()
            .ok_or_else(|| "unknown ref; use an [n] number from a search result or the context".to_string())
    }

    fn listing(&mut self, articles: Vec<ArticleWithFeed>, limit: usize) -> String {
        let mut lines = Vec::new();
        for article in articles.into_iter().take(limit) {
            let Some(n) = self.number(&article) else { break };
            lines.push(article_line(n, &article, &self.question));
        }
        if lines.is_empty() { "No matching articles.".into() } else { lines.join("\n") }
    }

    fn search(&self, scope: &str, terms: &[String], recent: bool) -> Result<Vec<ArticleWithFeed>, String> {
        let conn = self.db.conn.lock().map_err(|e| e.to_string())?;
        retrieve_chat_articles_for_terms(&conn, scope, terms, recent).map_err(|e| e.to_string())
    }

    fn step(&mut self, tool: &str, label: String) {
        self.steps.push(AgentStep { tool: tool.into(), label });
    }
}

fn scope_of(input: &serde_json::Value) -> &str {
    match input.get("scope").and_then(|s| s.as_str()) {
        Some("unread") => "unread",
        Some("starred") => "starred",
        _ => "all",
    }
}

fn limit_of(input: &serde_json::Value) -> usize {
    input.get("limit").and_then(|l| l.as_u64()).map(|l| l.clamp(1, 10) as usize).unwrap_or(8)
}

fn article_line(n: usize, article: &ArticleWithFeed, question: &str) -> String {
    let date = article
        .article
        .published_at
        .and_then(|t| chrono::DateTime::from_timestamp(t, 0))
        .map(|d| d.format("%Y-%m-%d").to_string())
        .unwrap_or_else(|| "undated".into());
    let state = match (article.article.is_read, article.article.is_starred) {
        (_, true) => "starred",
        (false, _) => "unread",
        _ => "read",
    };
    let body = crate::commands::article_body::feed_body_text(&article.article);
    let snippet: String = query_excerpt(&body, question, 220).split_whitespace().collect::<Vec<_>>().join(" ");
    format!("[{n}] {} ({}, {date}, {state}){}", article.article.title, article.feed_title,
        if snippet.is_empty() { String::new() } else { format!("\n    {snippet}") })
}

#[async_trait]
impl AgentTools for LibraryTools<'_> {
    async fn call(&mut self, call: &ToolCall) -> Result<String, String> {
        let input = &call.input;
        match call.name.as_str() {
            "search_articles" => {
                let query = input.get("query").and_then(|q| q.as_str()).unwrap_or("").trim().to_string();
                let terms = query_keywords(&query);
                if terms.is_empty() {
                    return Err("give a few topic words to search for".into());
                }
                self.step("search_articles", format!("Searched for \u{201c}{query}\u{201d}"));
                let limit = limit_of(input);
                let found = self.search(scope_of(input), &terms, false)?;
                Ok(self.listing(found, limit))
            }
            "recent_articles" => {
                self.step("recent_articles", "Looked at recent articles".into());
                let found = self.search(scope_of(input), &[], true)?;
                Ok(self.listing(found, 8))
            }
            "get_article" => {
                let article = self.by_ref(input)?;
                self.step("get_article", format!("Read \u{201c}{}\u{201d}", article.article.title));
                let text = crate::commands::article_body::resolve_article_text(self.db, &article.article).await;
                let excerpt = query_excerpt(&text, &self.question, 6000);
                Ok(format!(
                    "Title: {}\nSource: {}\nAuthor: {}\n{}\nURL: {}\nText:\n{}",
                    article.article.title,
                    article.feed_title,
                    article.article.author.as_deref().unwrap_or(""),
                    publication_context(article.article.published_at),
                    article.article.url.as_deref().unwrap_or(""),
                    if excerpt.is_empty() { "(no text available)".into() } else { excerpt },
                ))
            }
            "open_article" => {
                let article = self.by_ref(input)?;
                self.step("open_article", format!("Opened \u{201c}{}\u{201d}", article.article.title));
                let action = AgentAction { kind: "open_article".into(), article_id: article.article.id.clone() };
                if !self.actions.contains(&action) {
                    self.actions.push(action);
                }
                Ok("Opened in the reader.".into())
            }
            "web_search" => {
                let query = input.get("query").and_then(|q| q.as_str()).unwrap_or("").trim().to_string();
                if query.is_empty() {
                    return Err("web_search needs a query".into());
                }
                self.step("web_search", format!("Searched the web for \u{201c}{query}\u{201d}"));
                let results = run_web_search(&query, 5).await?;
                for r in &results {
                    if !self.web.iter().any(|c| c.url == r.url) {
                        self.web.push(WebCitation { title: r.title.clone(), url: r.url.clone(), snippet: r.snippet.clone(), query: query.clone() });
                    }
                }
                Ok(results.iter().map(|r| format!("- {} ({})\n    {}", r.title, r.url, r.snippet)).collect::<Vec<_>>().join("\n"))
            }
            other => Err(format!("unknown tool {other}")),
        }
    }
}

fn view_name(context: &AgentContext) -> String {
    let label = context.view_label.as_deref().filter(|l| !l.trim().is_empty());
    match (context.view.as_deref(), label) {
        (Some("today"), _) => "Today, the daily front page of top stories".into(),
        (Some("catchup"), _) => "Quick Catch-up, a briefing of what's new".into(),
        (Some("inbox"), _) => "the AI Inbox (articles ranked by priority)".into(),
        (Some("starred"), _) => "Starred articles".into(),
        (Some("recent"), _) => "Recently Read".into(),
        (Some("all"), _) => "All Articles".into(),
        (Some(_), Some(label)) => format!("the article list \u{201c}{label}\u{201d}"),
        (Some(view), None) => view.to_string(),
        (None, _) => "the app".into(),
    }
}

/// Describe the page, story and open article, numbering their articles so the
/// model can cite or open them without searching first.
async fn context_block(tools: &mut LibraryTools<'_>, context: &AgentContext) -> Result<String, String> {
    let mut out = format!("The user is looking at {}.", view_name(context));

    if !context.page_stories.is_empty() {
        out.push_str("\n\nStories on this page, in order:");
        for (i, story) in context.page_stories.iter().take(20).enumerate() {
            let mut refs = Vec::new();
            for id in story.article_ids.iter().take(3) {
                if let Some((n, _)) = tools.number_id(id)? {
                    refs.push(format!("[{n}]"));
                }
            }
            out.push_str(&format!("\n{}. {}", i + 1, story.title));
            if let Some(summary) = story.summary.as_deref().filter(|s| !s.trim().is_empty()) {
                let summary: String = summary.chars().take(240).collect();
                out.push_str(&format!(" - {summary}"));
            }
            if !refs.is_empty() {
                out.push_str(&format!(" {}", refs.join(" ")));
            }
        }
    }

    if let Some(story) = &context.story {
        out.push_str(&format!("\n\nThe user is focused on the story \u{201c}{}\u{201d}.", story.title));
        if let Some(summary) = story.summary.as_deref().filter(|s| !s.trim().is_empty()) {
            out.push_str(&format!(" Summary: {summary}"));
        }
        let mut lines = Vec::new();
        for id in story.article_ids.iter().take(8) {
            if let Some((n, article)) = tools.number_id(id)? {
                lines.push(format!("[{n}] {} ({})", article.article.title, article.feed_title));
            }
        }
        if !lines.is_empty() {
            out.push_str(&format!("\nIts reports:\n{}", lines.join("\n")));
        }
        out.push_str("\n\"This story\" means this one.");
    }

    if let Some(id) = &context.article_id {
        if let Some((n, article)) = tools.number_id(id)? {
            let text = crate::commands::article_body::resolve_article_text(tools.db, &article.article).await;
            let excerpt = query_excerpt(&text, &tools.question, 5000);
            out.push_str(&format!(
                "\n\nThe user has this article open in the reader. \"This article\" means this one.\n[{n}] Title: {}\nSource: {}\nAuthor: {}\n{}\nText:\n{}",
                article.article.title,
                article.feed_title,
                article.article.author.as_deref().unwrap_or(""),
                publication_context(article.article.published_at),
                excerpt,
            ));
        }
    }
    Ok(out)
}

#[tauri::command]
pub async fn ask_agent(
    app: AppHandle,
    db: State<'_, Database>,
    model_state: State<'_, SharedModelState>,
    messages: Vec<ChatMessageInput>,
    context: Option<AgentContext>,
    prior_article_ids: Option<Vec<String>>,
) -> Result<AgentResponse, String> {
    let question = messages
        .iter()
        .rev()
        .find(|m| m.role == "user")
        .map(|m| m.content.trim().to_string())
        .filter(|q| !q.is_empty())
        .ok_or("Question cannot be empty")?;
    let context = context.unwrap_or_default();

    let settings_json = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        queries::get_setting(&conn, "app_settings").map_err(|e| e.to_string())?
    };
    let settings: crate::db::models::AppSettings = settings_json
        .as_deref()
        .map(|s| serde_json::from_str(s).unwrap_or_default())
        .unwrap_or_default();
    let mut ai_settings = resolve_chat_settings(&settings.ai);
    if ai_settings.provider == "none" {
        return Err("No AI provider configured. Go to Settings to set up an AI provider.".to_string());
    }
    ai_settings.oauth_access_token = crate::ai::subscription_access_token(&db, &ai_settings.provider);
    let provider = create_provider_with_app(&ai_settings, Some(model_state.inner().clone()), &app)?;
    let model = ai_settings
        .model
        .clone()
        .unwrap_or_else(|| crate::commands::ai::default_model(&ai_settings.provider));

    let mut tools = LibraryTools::new(db.inner(), &question);
    for id in prior_article_ids.unwrap_or_default().iter().take(MAX_SOURCES) {
        tools.number_id(id)?;
    }
    let block = context_block(&mut tools, &context).await?;

    let mut chat = vec![ChatMessage::text("system", system_prompt(&block))];
    for message in &messages {
        if message.role == "user" || message.role == "assistant" {
            chat.push(ChatMessage::text(message.role.clone(), message.content.clone()));
        }
    }

    let content = run_agent_loop(provider.as_ref(), &model, chat, &mut tools).await?;

    let mut sources: Vec<ChatSource> = tools
        .sources
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
    for (index, w) in tools.web.iter().enumerate() {
        sources.push(ChatSource {
            id: format!("web-{index}"),
            title: w.title.clone(),
            feed_title: "Web".into(),
            url: Some(w.url.clone()),
            published_at: None,
            source_type: "web".into(),
        });
    }

    Ok(AgentResponse {
        content,
        provider: provider.name().to_string(),
        model,
        article_ids: tools.sources.iter().map(|a| a.article.id.clone()).collect(),
        sources,
        actions: tools.actions,
        steps: tools.steps,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ai::provider::ChatResponse as ProviderChatResponse;
    use std::sync::Mutex;

    struct Scripted {
        replies: Mutex<Vec<String>>,
        seen: Mutex<Vec<Vec<ChatMessage>>>,
    }

    impl Scripted {
        fn new(replies: &[&str]) -> Self {
            Self { replies: Mutex::new(replies.iter().rev().map(|r| r.to_string()).collect()), seen: Mutex::new(Vec::new()) }
        }
    }

    #[async_trait]
    impl AiProvider for Scripted {
        async fn chat(&self, request: ChatRequest) -> Result<ProviderChatResponse, String> {
            self.seen.lock().unwrap().push(request.messages.clone());
            let content = self.replies.lock().unwrap().pop().unwrap_or_else(|| "TOOL {\"name\":\"recent_articles\"}".into());
            Ok(ProviderChatResponse { content, model: "m".into(), usage: None, tool_uses: Vec::new(), stop_reason: None })
        }
        fn name(&self) -> &str { "scripted" }
    }

    #[derive(Default)]
    struct Recorder {
        calls: Vec<ToolCall>,
    }

    #[async_trait]
    impl AgentTools for Recorder {
        async fn call(&mut self, call: &ToolCall) -> Result<String, String> {
            self.calls.push(call.clone());
            if call.name == "search_articles" {
                Ok("[1] Rust async runtimes compared (Lobsters, 2026-10-10, unread)".into())
            } else {
                Err("nope".into())
            }
        }
    }

    #[test]
    fn parses_tool_lines_in_every_form_models_write_them() {
        let text = "Let me look.\nTOOL {\"name\": \"search_articles\", \"input\": {\"query\": \"rust async\"}}\n```\nTOOL: {\"name\":\"get_article\",\"ref\":2}\n```";
        let calls = parse_tool_calls(text);
        assert_eq!(calls.len(), 2);
        assert_eq!(calls[0].name, "search_articles");
        assert_eq!(calls[0].input["query"], "rust async");
        assert_eq!(calls[1].name, "get_article");
        assert_eq!(calls[1].input["ref"], 2);
        assert!(parse_tool_calls("No tools here, just [1].").is_empty());
        assert!(parse_tool_calls("TOOL not json").is_empty());
    }

    #[test]
    fn caps_calls_per_turn() {
        let line = "TOOL {\"name\":\"recent_articles\"}\n".repeat(10);
        assert_eq!(parse_tool_calls(&line).len(), MAX_CALLS_PER_ROUND);
    }

    #[tokio::test]
    async fn runs_tools_then_returns_the_prose_answer() {
        let provider = Scripted::new(&[
            "TOOL {\"name\":\"search_articles\",\"input\":{\"query\":\"rust async\"}}",
            "Here it is:\n- [1] Rust async runtimes compared",
        ]);
        let mut tools = Recorder::default();
        let answer = run_agent_loop(&provider, "m", vec![ChatMessage::text("user", "where's that rust async piece?")], &mut tools)
            .await
            .unwrap();
        assert_eq!(answer, "Here it is:\n- [1] Rust async runtimes compared");
        assert_eq!(tools.calls.len(), 1);
        let seen = provider.seen.lock().unwrap();
        let fed_back = &seen[1].last().unwrap().content;
        assert!(fed_back.starts_with("RESULT search_articles:"), "{fed_back}");
        assert!(fed_back.contains("Rust async runtimes compared"));
    }

    #[tokio::test]
    async fn tool_errors_go_back_to_the_model() {
        let provider = Scripted::new(&["TOOL {\"name\":\"get_article\",\"input\":{\"ref\":9}}", "Sorry, I couldn't read it."]);
        let mut tools = Recorder::default();
        let answer = run_agent_loop(&provider, "m", vec![ChatMessage::text("user", "read it")], &mut tools).await.unwrap();
        assert_eq!(answer, "Sorry, I couldn't read it.");
        let seen = provider.seen.lock().unwrap();
        assert!(seen[1].last().unwrap().content.contains("error: nope"));
    }

    #[tokio::test]
    async fn a_model_that_never_stops_calling_tools_is_made_to_answer() {
        let provider = Scripted::new(&[]);
        let mut tools = Recorder::default();
        let answer = run_agent_loop(&provider, "m", vec![ChatMessage::text("user", "hi")], &mut tools).await.unwrap();
        // The final turn ignores tool lines and strips them from the answer.
        assert_eq!(answer, "I couldn't find an answer to that.");
        assert_eq!(tools.calls.len(), MAX_ROUNDS - 1);
        let seen = provider.seen.lock().unwrap();
        assert!(seen.last().unwrap().last().unwrap().content.contains("tool budget used up"));
    }

    fn library() -> Database {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        crate::db::migrations::run_migrations(&conn).unwrap();
        conn.execute_batch("INSERT INTO feeds(id,title,url,created_at,updated_at) VALUES ('f','Lobsters','https://feed.test',0,0);
            INSERT INTO articles(id,feed_id,title,url,content_text,published_at,fetched_at,is_read,is_starred) VALUES
            ('a1','f','Rust async runtimes compared','https://x.test/rust','Tokio and smol benchmarks',100,100,0,0),
            ('a2','f','Gardening in October','https://x.test/garden','Bulbs and frost',200,200,1,1);").unwrap();
        Database { conn: std::sync::Mutex::new(conn), data_dir: std::env::temp_dir() }
    }

    #[tokio::test]
    async fn library_tools_search_number_and_open_articles() {
        let db = library();
        let mut tools = LibraryTools::new(&db, "where's the rust async article");
        let found = tools
            .call(&ToolCall { name: "search_articles".into(), input: serde_json::json!({"query": "rust async"}) })
            .await
            .unwrap();
        assert!(found.starts_with("[1] Rust async runtimes compared (Lobsters, 1970-01-01, unread)"), "{found}");
        let starred = tools
            .call(&ToolCall { name: "search_articles".into(), input: serde_json::json!({"query": "gardening", "scope": "starred"}) })
            .await
            .unwrap();
        assert!(starred.starts_with("[2] Gardening in October"), "{starred}");
        let opened = tools.call(&ToolCall { name: "open_article".into(), input: serde_json::json!({"ref": 1}) }).await.unwrap();
        assert_eq!(opened, "Opened in the reader.");
        assert_eq!(tools.actions, vec![AgentAction { kind: "open_article".into(), article_id: "a1".into() }]);
        assert!(tools.call(&ToolCall { name: "open_article".into(), input: serde_json::json!({"ref": 7}) }).await.is_err());
        assert_eq!(tools.steps.len(), 3);
    }

    #[tokio::test]
    async fn context_numbers_page_stories_and_the_focused_story() {
        let db = library();
        let mut tools = LibraryTools::new(&db, "what's this story about?");
        tools.number_id("a2").unwrap(); // a prior turn's citation keeps its number
        let context = AgentContext {
            view: Some("today".into()),
            page_stories: vec![AgentStory { story_id: "s1".into(), title: "Async Rust".into(), summary: Some("Runtimes".into()), article_ids: vec!["a1".into()] }],
            story: Some(AgentStory { story_id: "s1".into(), title: "Async Rust".into(), summary: None, article_ids: vec!["a1".into(), "missing".into()] }),
            ..Default::default()
        };
        let block = context_block(&mut tools, &context).await.unwrap();
        assert!(block.starts_with("The user is looking at Today"), "{block}");
        assert!(block.contains("1. Async Rust - Runtimes [2]"), "{block}");
        assert!(block.contains("focused on the story \u{201c}Async Rust\u{201d}"), "{block}");
        assert!(block.contains("[2] Rust async runtimes compared (Lobsters)"), "{block}");
        assert_eq!(tools.sources.len(), 2);
    }
}
