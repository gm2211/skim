use crate::ai::local_provider::SharedModelState;
use crate::ai::provider::{
    create_provider_with_app, AiProvider, ChatMessage, ChatRequest, ChatResponse as ProviderChatResponse,
    ToolDef, ToolUse,
};
use crate::db::models::AiSettings;
use crate::db::{queries, Database};
use serde::{Deserialize, Serialize};
use crate::AppHandle;
use tauri::State;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatMessageInput {
    pub role: String,
    pub content: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatResponse {
    pub content: String,
    pub provider: String,
    pub model: String,
    /// Web-search citations the tool-use loop produced, when the provider
    /// supports tools. Empty for other providers / turns where no search ran.
    #[serde(default)]
    pub web_citations: Vec<WebCitation>,
}

#[tauri::command]
pub async fn chat_with_article(
    app: AppHandle,
    db: State<'_, Database>,
    model_state: State<'_, SharedModelState>,
    article_id: String,
    messages: Vec<ChatMessageInput>,
) -> Result<ChatResponse, String> {
    let (article, settings_json) = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        let article = queries::get_article_by_id(&conn, &article_id)
            .map_err(|e| e.to_string())?
            .ok_or("Article not found")?;
        let settings_json =
            queries::get_setting(&conn, "app_settings").map_err(|e| e.to_string())?;
        (article, settings_json)
    };

    let settings: crate::db::models::AppSettings = settings_json
        .as_deref()
        .map(|s| serde_json::from_str(s).unwrap_or_default())
        .unwrap_or_default();

    // Use chat-specific provider/model if configured, otherwise fall back to main AI settings
    let mut ai_settings = resolve_chat_settings(&settings.ai);

    if ai_settings.provider == "none" {
        return Err(
            "No AI provider configured. Go to Settings to set up an AI provider.".to_string(),
        );
    }

    ai_settings.oauth_access_token = crate::ai::claude_oauth::stored_access_token(&db);
    let provider_kind = ai_settings.provider.clone();
    let provider = create_provider_with_app(&ai_settings, Some(model_state.inner().clone()), &app)?;
    let model = ai_settings
        .model
        .clone()
        .unwrap_or_else(|| crate::commands::ai::default_model(&ai_settings.provider));

    // Build article context from the same text the reader shows — the feed
    // body alone is a blurb on summary-only feeds, and answering a question
    // about a paragraph on screen from two sentences of teaser is worse than
    // not answering.
    let text = crate::commands::article_body::resolve_article_text(db.inner(), &article.article).await;

    // Truncate for context window (char-safe)
    let article_text: String = text.chars().take(12000).collect();

    let tool_hint = if provider_supports_tools(&provider_kind) {
        "When the article doesn't contain enough information to answer, you may call the \
         `web_search` tool to pull in fresh results. Prefer article context when it suffices.\n\n"
    } else {
        ""
    };
    let mut system_prompt = format!(
        "You are a helpful assistant discussing a news article. Answer questions about the article, \
         provide context, and help the user understand the topic better. Be concise and direct. \
         No emoji.\n\n{tool_hint}\
         Article Title: {title}\n\
         Source: {source}\n\
         Author: {author}\n\n\
         Article Content:\n{body}",
        tool_hint = tool_hint,
        title = article.article.title,
        source = article.feed_title,
        author = article.article.author.as_deref().unwrap_or("Unknown"),
        body = article_text,
    );

    let mut local_citations = Vec::new();
    if ai_settings.provider == "mlx" && ai_settings.local_chat_web_search.unwrap_or(true) {
        if let Some(results) = local_chat_search(provider.as_ref(), &model, &article_text, &messages).await {
            system_prompt.push_str("\n\n");
            system_prompt.push_str(&format_web_results_block(&results));
            local_citations = results
                .iter()
                .map(|result| WebCitation {
                    title: result.title.clone(),
                    url: result.url.clone(),
                    snippet: result.snippet.clone(),
                    query: latest_user_question(&messages).unwrap_or_default(),
                })
                .collect();
        }
    }

    let mut chat_messages = vec![ChatMessage::text("system", system_prompt)];

    for msg in &messages {
        chat_messages.push(ChatMessage::text(msg.role.clone(), msg.content.clone()));
    }

    let (content, mut web_citations) = invoke_chat_with_tools(
        provider.as_ref(),
        &provider_kind,
        chat_messages,
        model.clone(),
        Some(0.5),
        Some(2048),
    )
    .await?;
    web_citations.extend(local_citations);

    // Track chat interaction for learning system
    {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        let now = chrono::Utc::now().timestamp();
        let _ = queries::increment_chat_count(&conn, &article_id, now);
    }

    Ok(ChatResponse {
        content,
        provider: provider.name().to_string(),
        model,
        web_citations,
    })
}

#[derive(Debug, Clone, Serialize)]
pub struct ArticleChatResponse {
    pub content: String,
    pub provider: String,
    pub model: String,
    pub article_ids: Vec<String>,
    pub sources: Vec<ChatSource>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ChatSource {
    pub id: String,
    pub title: String,
    pub feed_title: String,
    pub url: Option<String>,
    pub published_at: Option<i64>,
    /// "article" for items pulled from the user's feed, "web" for items
    /// surfaced by the web_search tool during a tool-use loop. Frontend
    /// renders a globe icon for web sources.
    pub source_type: String,
}

/// A web-search result hoisted into the response so the frontend can render
/// separate globe citations without mixing them into `article_ids`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WebCitation {
    pub title: String,
    pub url: String,
    pub snippet: String,
    /// The query the model issued to produce this citation. Useful in the UI
    /// if several searches happen across tool iterations.
    pub query: String,
}

/// Extract lowercase word stems (3+ chars) from a query for keyword matching.
fn query_keywords(query: &str) -> Vec<String> {
    query
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| w.len() >= 3)
        .map(|w| w.to_lowercase())
        .collect()
}

/// On a summary-only feed the stored body is a one-line teaser, so an excerpt
/// taken from it says almost nothing. Prefer the reader's cached extraction
/// where there is one. Stays off the network: this runs once per candidate
/// article on every question.
fn article_excerpt(
    db: &Database,
    a: &crate::db::models::ArticleWithFeed,
    max_chars: usize,
) -> String {
    crate::commands::article_body::local_article_text(db, &a.article)
        .chars()
        .take(max_chars)
        .collect()
}

/// Chat across multiple articles. Scope determines which articles form the
/// candidate pool; the user's query is then used to keyword-rank them so the
/// prompt stays within a reasonable context budget.
#[tauri::command]
pub async fn chat_with_articles(
    app: AppHandle,
    db: State<'_, Database>,
    model_state: State<'_, SharedModelState>,
    scope: String,
    query: String,
    messages: Vec<ChatMessageInput>,
) -> Result<ArticleChatResponse, String> {
    let trimmed_query = query.trim().to_string();
    if trimmed_query.is_empty() {
        return Err("Query cannot be empty".to_string());
    }

    let (pool, settings_json) = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        let settings_json =
            queries::get_setting(&conn, "app_settings").map_err(|e| e.to_string())?;
        let pool: Vec<crate::db::models::ArticleWithFeed> = match scope.as_str() {
            "inbox" => {
                let inbox = queries::get_inbox_articles(&conn, Some(3), None, 500, 0)
                    .map_err(|e| e.to_string())?;
                inbox
                    .into_iter()
                    .map(|a| crate::db::models::ArticleWithFeed {
                        article: a.article,
                        feed_title: a.feed_title,
                        feed_icon_url: a.feed_icon_url,
                    })
                    .collect()
            }
            "unread" => queries::get_articles(
                &conn,
                &crate::db::models::ArticleFilter {
                    feed_id: None,
                    feed_ids: None,
                    search: None,
                    theme_id: None,
                    is_read: Some(false),
                    is_starred: None,
                    limit: Some(500),
                    published_after: None,
                    offset: None,
                },
            )
            .map_err(|e| e.to_string())?,
            _ => queries::get_articles(
                &conn,
                &crate::db::models::ArticleFilter {
                    feed_id: None,
                    feed_ids: None,
                    search: None,
                    theme_id: None,
                    is_read: None,
                    is_starred: None,
                    limit: Some(1000),
                    published_after: None,
                    offset: None,
                },
            )
            .map_err(|e| e.to_string())?,
        };
        (pool, settings_json)
    };

    let settings: crate::db::models::AppSettings = settings_json
        .as_deref()
        .map(|s| serde_json::from_str(s).unwrap_or_default())
        .unwrap_or_default();

    let mut ai_settings = resolve_chat_settings(&settings.ai);
    if ai_settings.provider == "none" {
        return Err(
            "No AI provider configured. Go to Settings to set up an AI provider.".to_string(),
        );
    }

    ai_settings.oauth_access_token = crate::ai::claude_oauth::stored_access_token(&db);
    let provider_kind = ai_settings.provider.clone();
    let provider = create_provider_with_app(&ai_settings, Some(model_state.inner().clone()), &app)?;
    let model = ai_settings
        .model
        .clone()
        .unwrap_or_else(|| crate::commands::ai::default_model(&ai_settings.provider));

    // Rank articles by keyword overlap with the query + conversation history.
    let mut haystack_query = trimmed_query.to_lowercase();
    for m in &messages {
        haystack_query.push(' ');
        haystack_query.push_str(&m.content.to_lowercase());
    }
    let kws = query_keywords(&haystack_query);

    let mut scored: Vec<(i64, &crate::db::models::ArticleWithFeed)> = pool
        .iter()
        .map(|a| {
            let hay = format!(
                "{} {} {}",
                a.article.title.to_lowercase(),
                a.feed_title.to_lowercase(),
                a.article
                    .content_text
                    .as_deref()
                    .unwrap_or("")
                    .to_lowercase(),
            );
            let score: i64 = kws.iter().filter(|k| hay.contains(k.as_str())).count() as i64;
            (score, a)
        })
        .collect();
    scored.sort_by(|a, b| b.0.cmp(&a.0));
    // If no keywords match anything, fall back to the newest articles.
    let any_match = scored.first().map(|(s, _)| *s > 0).unwrap_or(false);
    let top_k = if any_match { 15 } else { 8 };
    let selected: Vec<&crate::db::models::ArticleWithFeed> =
        scored.into_iter().take(top_k).map(|(_, a)| a).collect();

    // Build context. Keep excerpts short to stay well under any argv or
    // context window limits — the caller mostly needs titles and source.
    let mut context = String::new();
    context.push_str("Relevant articles from the user's RSS feed:\n\n");
    for (i, a) in selected.iter().enumerate() {
        let date = a
            .article
            .published_at
            .map(|ts| {
                chrono::DateTime::from_timestamp(ts, 0)
                    .map(|d| d.format("%Y-%m-%d").to_string())
                    .unwrap_or_default()
            })
            .unwrap_or_default();
        let excerpt = article_excerpt(db.inner(), a, 400);
        context.push_str(&format!(
            "[{i}] Title: {title}\nSource: {source}\nAuthor: {author}\nDate: {date}\nURL: {url}\nExcerpt: {excerpt}\n\n",
            i = i + 1,
            title = a.article.title,
            source = a.feed_title,
            author = a.article.author.as_deref().unwrap_or(""),
            url = a.article.url.as_deref().unwrap_or(""),
            excerpt = excerpt,
        ));
    }

    let tool_clause = if provider_supports_tools(&provider_kind) {
        "If the articles don't contain the answer, call the `web_search` tool to pull in fresh \
         web results before saying you can't answer. "
    } else {
        ""
    };
    let system_prompt = format!(
        "You answer the user's questions about articles from their RSS feed. Prefer the articles \
         below as evidence and cite them with their bracket number like [2]. \
         {tool_clause}Be concise. No emoji.\n\n{context}",
        tool_clause = tool_clause,
        context = context,
    );

    let mut chat_messages = vec![ChatMessage::text("system", system_prompt)];
    for msg in &messages {
        chat_messages.push(ChatMessage::text(msg.role.clone(), msg.content.clone()));
    }
    chat_messages.push(ChatMessage::text("user", trimmed_query));

    let (content, web_citations) = invoke_chat_with_tools(
        provider.as_ref(),
        &provider_kind,
        chat_messages,
        model.clone(),
        Some(0.4),
        Some(2048),
    )
    .await?;

    let mut sources: Vec<ChatSource> = selected
        .iter()
        .map(|a| ChatSource {
            id: a.article.id.clone(),
            title: a.article.title.clone(),
            feed_title: a.feed_title.clone(),
            url: a.article.url.clone(),
            published_at: a.article.published_at,
            source_type: "article".to_string(),
        })
        .collect();

    // Merge web citations into sources as well, so the existing Ask Skim UI
    // (which only reads `sources`) can render them without a separate field.
    for (idx, w) in web_citations.iter().enumerate() {
        sources.push(ChatSource {
            id: format!("web-{idx}"),
            title: w.title.clone(),
            feed_title: "Web".to_string(),
            url: Some(w.url.clone()),
            published_at: None,
            source_type: "web".to_string(),
        });
    }

    Ok(ArticleChatResponse {
        content,
        provider: provider.name().to_string(),
        model,
        article_ids: selected.iter().map(|a| a.article.id.clone()).collect(),
        sources,
    })
}

/// Providers that support the tool-use loop. Must match names returned by
/// `AiProvider::name()` / `AiSettings::provider`.
fn provider_supports_tools(provider_kind: &str) -> bool {
    // ClaudeCliProvider is intentionally excluded: Claude Code sees the tool
    // spec and emits `tool_use` blocks that the subprocess wrapper can't
    // resolve, leading to `stop_reason=tool_use` + `subtype=error_max_turns`
    // with no result text. Until the CLI gets a tool-loop bridge, it's
    // text-only.
    matches!(provider_kind, "anthropic" | "claude-subscription")
}

fn latest_user_question(messages: &[ChatMessageInput]) -> Option<String> {
    messages
        .iter()
        .rev()
        .find(|message| message.role == "user")
        .map(|message| message.content.trim().to_string())
        .filter(|question| !question.is_empty())
}

fn can_skip_local_search(question: &str) -> bool {
    let lower = question.to_lowercase();
    if lower.split_whitespace().count() > 8 {
        return false;
    }
    ![
        "latest", "current", "today", "now", "recent", "price", "weather", "who won",
        "look up", "search", "google",
    ]
    .iter()
    .any(|token| lower.contains(token))
}

fn parse_local_search_query(response: &str) -> Option<String> {
    let line = response.lines().next()?.trim();
    let query = line.strip_prefix("SEARCH:")?.trim();
    (!query.is_empty()).then(|| query.chars().take(240).collect())
}

fn format_web_results_block(results: &[SearchResult]) -> String {
    let body = results
        .iter()
        .enumerate()
        .map(|(index, result)| {
            format!("(W{}) {}\n    {}\n    {}", index + 1, result.title, result.snippet, result.url)
        })
        .collect::<Vec<_>>()
        .join("\n");
    format!("Web search results (use for facts not in the article; answer in prose):\n{body}")
}

async fn local_chat_search(
    provider: &dyn AiProvider,
    model: &str,
    article_context: &str,
    messages: &[ChatMessageInput],
) -> Option<Vec<SearchResult>> {
    let question = latest_user_question(messages)?;
    if can_skip_local_search(&question) {
        return None;
    }
    let route = provider
        .chat(ChatRequest {
            model: model.to_string(),
            messages: vec![
                ChatMessage::text(
                    "system",
                    "Decide whether to answer from the article or search the web. Reply with exactly ANSWER or SEARCH: <concise query>. If unsure, reply ANSWER.",
                ),
                ChatMessage::text("user", format!("Article:\n{article_context}\n\nQuestion: {question}")),
            ],
            temperature: None,
            max_tokens: Some(24),
            json_mode: false,
            tools: None,
        })
        .await
        .ok()?;
    let query = parse_local_search_query(&route.content)?;
    run_web_search(&query, 5).await.ok().filter(|results| !results.is_empty())
}

/// Web-search tool definition shared between per-article and multi-article
/// chat. Anthropic-compatible JSON schema.
fn web_search_tool_def() -> ToolDef {
    ToolDef {
        name: "web_search".to_string(),
        description: "Search the public web (DuckDuckGo) for fresh information not present in the \
             user's article context. Returns up to `max_results` title/url/snippet tuples. \
             Call this when the provided articles don't cover the user's question."
            .to_string(),
        input_schema: serde_json::json!({
            "type": "object",
            "properties": {
                "query": { "type": "string", "description": "Search query." },
                "max_results": {
                    "type": "integer",
                    "description": "Max results to return (1-10). Defaults to 5.",
                    "minimum": 1,
                    "maximum": 10
                }
            },
            "required": ["query"]
        }),
    }
}

/// Run the provider chat, optionally looping through tool_use → tool_result
/// rounds. Caps at 3 tool iterations. Returns the final assistant text plus
/// any web-search citations the model produced along the way.
///
/// For providers that don't support tool-use, this short-circuits to a single
/// provider call and returns an empty citation list — `web_search` is simply
/// not advertised.
async fn invoke_chat_with_tools(
    provider: &dyn AiProvider,
    provider_kind: &str,
    mut messages: Vec<ChatMessage>,
    model: String,
    temperature: Option<f64>,
    max_tokens: Option<i64>,
) -> Result<(String, Vec<WebCitation>), String> {
    let supports_tools = provider_supports_tools(provider_kind);
    if !supports_tools {
        log::info!(
            "chat: provider '{}' does not support tool-use; skipping web_search tool registration",
            provider_kind
        );
    }

    let tools = if supports_tools {
        Some(vec![web_search_tool_def()])
    } else {
        None
    };

    let mut citations: Vec<WebCitation> = Vec::new();
    let max_iterations = 3;

    for iteration in 0..=max_iterations {
        let req = ChatRequest {
            model: model.clone(),
            messages: messages.clone(),
            temperature,
            max_tokens,
            json_mode: false,
            tools: tools.clone(),
        };
        let response: ProviderChatResponse = provider.chat(req).await?;

        // No tool calls → final response.
        if response.tool_uses.is_empty() {
            return Ok((response.content, citations));
        }

        if iteration == max_iterations {
            log::warn!(
                "chat: reached max tool-use iterations ({}); returning partial content",
                max_iterations
            );
            return Ok((response.content, citations));
        }

        // Replay the assistant's tool_use turn verbatim as content_blocks so
        // the provider sees the `tool_use_id`s on the next round.
        let assistant_blocks = build_assistant_tool_use_blocks(&response);
        messages.push(ChatMessage {
            role: "assistant".to_string(),
            content: String::new(),
            content_blocks: Some(assistant_blocks),
        });

        // Execute each tool call and append a single user turn with all
        // `tool_result` blocks.
        let mut result_blocks: Vec<serde_json::Value> = Vec::new();
        for tu in &response.tool_uses {
            let block = execute_tool(tu, &mut citations).await;
            result_blocks.push(block);
        }
        messages.push(ChatMessage {
            role: "user".to_string(),
            content: String::new(),
            content_blocks: Some(result_blocks),
        });
    }

    // Unreachable in practice — the loop always returns within max_iterations.
    unreachable!("tool-use loop exited without returning")
}

/// Rebuild the assistant's content blocks so they can be replayed to the
/// provider on the next round. We preserve the leading text (if any) and then
/// each `tool_use` block with its id/name/input.
fn build_assistant_tool_use_blocks(response: &ProviderChatResponse) -> Vec<serde_json::Value> {
    let mut blocks: Vec<serde_json::Value> = Vec::new();
    if !response.content.is_empty() {
        blocks.push(serde_json::json!({
            "type": "text",
            "text": response.content,
        }));
    }
    for tu in &response.tool_uses {
        blocks.push(serde_json::json!({
            "type": "tool_use",
            "id": tu.id,
            "name": tu.name,
            "input": tu.input,
        }));
    }
    blocks
}

/// Dispatch a single tool invocation. Unknown tools are reported back as
/// errors so the model can recover on its next turn.
async fn execute_tool(tu: &ToolUse, citations: &mut Vec<WebCitation>) -> serde_json::Value {
    match tu.name.as_str() {
        "web_search" => {
            let query = tu
                .input
                .get("query")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .trim()
                .to_string();
            let max_results = tu
                .input
                .get("max_results")
                .and_then(|v| v.as_u64())
                .map(|n| n.clamp(1, 10) as usize)
                .unwrap_or(5);
            if query.is_empty() {
                return serde_json::json!({
                    "type": "tool_result",
                    "tool_use_id": tu.id,
                    "is_error": true,
                    "content": "web_search called with empty query",
                });
            }
            match run_web_search(&query, max_results).await {
                Ok(results) => {
                    // Capture citations for the UI.
                    for r in &results {
                        // Avoid duplicates across iterations.
                        if !citations.iter().any(|c| c.url == r.url) {
                            citations.push(WebCitation {
                                title: r.title.clone(),
                                url: r.url.clone(),
                                snippet: r.snippet.clone(),
                                query: query.clone(),
                            });
                        }
                    }
                    let payload = serde_json::json!({
                        "query": query,
                        "results": results,
                    });
                    serde_json::json!({
                        "type": "tool_result",
                        "tool_use_id": tu.id,
                        "content": payload.to_string(),
                    })
                }
                Err(e) => serde_json::json!({
                    "type": "tool_result",
                    "tool_use_id": tu.id,
                    "is_error": true,
                    "content": format!("web_search failed: {}", e),
                }),
            }
        }
        other => serde_json::json!({
            "type": "tool_result",
            "tool_use_id": tu.id,
            "is_error": true,
            "content": format!("Unknown tool: {}", other),
        }),
    }
}

#[tauri::command]
pub async fn web_search(query: String) -> Result<Vec<SearchResult>, String> {
    run_web_search(&query, 5).await
}

/// Actual DuckDuckGo HTML scrape. Factored out of the Tauri command so the
/// tool-use loop and the direct UI call share one implementation.
pub async fn run_web_search(query: &str, max_results: usize) -> Result<Vec<SearchResult>, String> {
    let client = reqwest::Client::builder()
        .user_agent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36")
        .build()
        .map_err(|e| e.to_string())?;

    let url = format!(
        "https://html.duckduckgo.com/html/?q={}",
        urlencoding::encode(query)
    );

    let html = client
        .get(&url)
        .send()
        .await
        .map_err(|e| format!("Search request failed: {}", e))?
        .text()
        .await
        .map_err(|e| format!("Failed to read search response: {}", e))?;

    let mut results = parse_ddg_results(&html);
    results.truncate(max_results);
    Ok(results)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchResult {
    pub title: String,
    pub url: String,
    pub snippet: String,
}

fn parse_ddg_results(html: &str) -> Vec<SearchResult> {
    let mut results = Vec::new();

    // Parse DuckDuckGo HTML results - they use class="result__a" for links
    // and class="result__snippet" for snippets
    for chunk in html.split("class=\"result__body") {
        if results.len() >= 10 {
            break;
        }

        // Extract title and URL from result__a
        let title_url = if let Some(a_start) = chunk.find("class=\"result__a\"") {
            let after_a = &chunk[a_start..];
            let href = extract_attr(after_a, "href");
            let title = extract_tag_text(after_a, "a");
            (title, href)
        } else {
            continue;
        };

        // Extract snippet
        let snippet = if let Some(s_start) = chunk.find("class=\"result__snippet\"") {
            let after_s = &chunk[s_start..];
            extract_tag_text(after_s, "a")
                .or_else(|| extract_inner_text(after_s))
                .unwrap_or_default()
        } else {
            String::new()
        };

        if let (Some(title), Some(url)) = (title_url.0, title_url.1) {
            // DDG wraps URLs in a redirect - extract the actual URL
            let actual_url = if url.contains("uddg=") {
                url.split("uddg=")
                    .nth(1)
                    .and_then(|u| u.split('&').next())
                    .map(|u| urlencoding::decode(u).unwrap_or_default().into_owned())
                    .unwrap_or(url)
            } else {
                url
            };

            if !title.is_empty() && actual_url.starts_with("http") {
                results.push(SearchResult {
                    title: html_entities_decode(&title),
                    url: actual_url,
                    snippet: html_entities_decode(&snippet),
                });
            }
        }
    }

    results
}

fn extract_attr(html: &str, attr: &str) -> Option<String> {
    let pattern = format!("{}=\"", attr);
    let start = html.find(&pattern)? + pattern.len();
    let end = html[start..].find('"')? + start;
    Some(html[start..end].to_string())
}

fn extract_tag_text(html: &str, tag: &str) -> Option<String> {
    let open_end = html.find('>')?;
    let close = html.find(&format!("</{}", tag))?;
    if open_end + 1 >= close {
        return None;
    }
    let inner = &html[open_end + 1..close];
    // Strip any nested tags
    Some(strip_html_tags(inner).trim().to_string())
}

fn extract_inner_text(html: &str) -> Option<String> {
    let open_end = html.find('>')?;
    // Find the next closing tag
    let rest = &html[open_end + 1..];
    let close = rest.find("</")?;
    let inner = &rest[..close];
    let text = strip_html_tags(inner).trim().to_string();
    if text.is_empty() {
        None
    } else {
        Some(text)
    }
}

fn strip_html_tags(s: &str) -> String {
    let mut result = String::new();
    let mut in_tag = false;
    for ch in s.chars() {
        match ch {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => result.push(ch),
            _ => {}
        }
    }
    result
}

fn html_entities_decode(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#x27;", "'")
        .replace("&#39;", "'")
        .replace("&nbsp;", " ")
}

/// Resolve chat-specific AI settings, falling back to main settings
fn resolve_chat_settings(ai: &AiSettings) -> AiSettings {
    let mut settings = ai.clone();

    if let Some(ref chat_provider) = ai.chat_provider {
        if !chat_provider.is_empty() && chat_provider != "same" {
            settings.provider = chat_provider.clone();
            settings.api_key = ai.chat_api_key.clone().or(ai.api_key.clone());
            settings.endpoint = ai.chat_endpoint.clone().or(ai.endpoint.clone());
        }
    }

    if let Some(ref chat_model) = ai.chat_model {
        if !chat_model.is_empty() {
            settings.model = Some(chat_model.clone());
        }
    }

    settings
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_router_skips_short_article_questions_without_freshness_terms() {
        assert!(can_skip_local_search("What is the main argument?"));
        assert!(!can_skip_local_search("What is the latest price today?"));
        assert!(!can_skip_local_search("Explain the article and compare it with other recent work"));
    }

    #[test]
    fn local_router_accepts_only_explicit_search_lines() {
        assert_eq!(parse_local_search_query("SEARCH: Rust async runtime"), Some("Rust async runtime".into()));
        assert_eq!(parse_local_search_query("ANSWER"), None);
        assert_eq!(parse_local_search_query("SEARCH:"), None);
    }

    #[test]
    fn web_context_is_numbered_and_keeps_source_urls() {
        let results = vec![SearchResult {
            title: "A result".into(),
            url: "https://example.com/a".into(),
            snippet: "A snippet".into(),
        }];
        let block = format_web_results_block(&results);
        assert!(block.contains("(W1) A result"));
        assert!(block.contains("https://example.com/a"));
    }
}
