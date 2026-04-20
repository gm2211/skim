use crate::ai::local_provider::SharedModelState;
use crate::ai::provider::{ChatMessage, ChatRequest, create_provider};
use crate::db::models::AiSettings;
use crate::db::{queries, Database};
use serde::{Deserialize, Serialize};
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
}

#[tauri::command]
pub async fn chat_with_article(
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
        let settings_json = queries::get_setting(&conn, "app_settings")
            .map_err(|e| e.to_string())?;
        (article, settings_json)
    };

    let settings: crate::db::models::AppSettings = settings_json
        .as_deref()
        .map(|s| serde_json::from_str(s).unwrap_or_default())
        .unwrap_or_default();

    // Use chat-specific provider/model if configured, otherwise fall back to main AI settings
    let ai_settings = resolve_chat_settings(&settings.ai);

    if ai_settings.provider == "none" {
        return Err("No AI provider configured. Go to Settings to set up an AI provider.".to_string());
    }

    let provider = create_provider(&ai_settings, Some(model_state.inner().clone()))?;
    let model = ai_settings.model.clone().unwrap_or_else(|| crate::commands::ai::default_model(&ai_settings.provider));

    // Build article context
    let content_text = article.article.content_text.as_deref().unwrap_or("");
    let html_as_text = article.article.content_html.as_deref()
        .map(|h| html2text::from_read(h.as_bytes(), 10000))
        .unwrap_or_default();
    let text = if html_as_text.len() > content_text.len() { &html_as_text } else { content_text };

    // Truncate for context window (char-safe)
    let article_text: String = text.chars().take(12000).collect();

    let system_prompt = format!(
        "You are a helpful assistant discussing a news article. Answer questions about the article, \
         provide context, and help the user understand the topic better. Be concise and direct. \
         No emoji.\n\n\
         Article Title: {}\n\
         Source: {}\n\
         Author: {}\n\n\
         Article Content:\n{}",
        article.article.title,
        article.feed_title,
        article.article.author.as_deref().unwrap_or("Unknown"),
        article_text,
    );

    let mut chat_messages = vec![
        ChatMessage {
            role: "system".to_string(),
            content: system_prompt,
        },
    ];

    for msg in &messages {
        chat_messages.push(ChatMessage {
            role: msg.role.clone(),
            content: msg.content.clone(),
        });
    }

    let req = ChatRequest {
        model: model.clone(),
        messages: chat_messages,
        temperature: Some(0.5),
        max_tokens: Some(2048),
        json_mode: false,
    };

    let response = provider.chat(req).await?;

    // Track chat interaction for learning system
    {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        let now = chrono::Utc::now().timestamp();
        let _ = queries::increment_chat_count(&conn, &article_id, now);
    }

    Ok(ChatResponse {
        content: response.content,
        provider: provider.name().to_string(),
        model,
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
}

/// Extract lowercase word stems (3+ chars) from a query for keyword matching.
fn query_keywords(query: &str) -> Vec<String> {
    query
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| w.len() >= 3)
        .map(|w| w.to_lowercase())
        .collect()
}

fn article_excerpt(a: &crate::db::models::ArticleWithFeed, max_chars: usize) -> String {
    let content_text = a.article.content_text.as_deref().unwrap_or("");
    let html_text = a
        .article
        .content_html
        .as_deref()
        .map(|h| html2text::from_read(h.as_bytes(), 10000))
        .unwrap_or_default();
    let src = if html_text.len() > content_text.len() {
        html_text
    } else {
        content_text.to_string()
    };
    src.chars().take(max_chars).collect()
}

/// Chat across multiple articles. Scope determines which articles form the
/// candidate pool; the user's query is then used to keyword-rank them so the
/// prompt stays within a reasonable context budget.
#[tauri::command]
pub async fn chat_with_articles(
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
        let settings_json = queries::get_setting(&conn, "app_settings").map_err(|e| e.to_string())?;
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
                    theme_id: None,
                    is_read: Some(false),
                    is_starred: None,
                    limit: Some(500),
                    offset: None,
                },
            )
            .map_err(|e| e.to_string())?,
            _ => queries::get_articles(
                &conn,
                &crate::db::models::ArticleFilter {
                    feed_id: None,
                    theme_id: None,
                    is_read: None,
                    is_starred: None,
                    limit: Some(1000),
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

    let ai_settings = resolve_chat_settings(&settings.ai);
    if ai_settings.provider == "none" {
        return Err("No AI provider configured. Go to Settings to set up an AI provider.".to_string());
    }

    let provider = create_provider(&ai_settings, Some(model_state.inner().clone()))?;
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
                a.article.content_text.as_deref().unwrap_or("").to_lowercase(),
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
        let excerpt = article_excerpt(a, 400);
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

    let system_prompt = format!(
        "You answer the user's questions about articles from their RSS feed. Use ONLY the articles below as evidence. \
         When you reference an article, cite it with its bracket number like [2]. \
         If the articles don't contain the answer, say so and suggest broadening the search. \
         Be concise. No emoji.\n\n{}",
        context,
    );

    let mut chat_messages = vec![ChatMessage {
        role: "system".to_string(),
        content: system_prompt,
    }];
    for msg in &messages {
        chat_messages.push(ChatMessage {
            role: msg.role.clone(),
            content: msg.content.clone(),
        });
    }
    chat_messages.push(ChatMessage {
        role: "user".to_string(),
        content: trimmed_query,
    });

    let req = ChatRequest {
        model: model.clone(),
        messages: chat_messages,
        temperature: Some(0.4),
        max_tokens: Some(2048),
        json_mode: false,
    };

    let response = provider.chat(req).await?;

    let sources: Vec<ChatSource> = selected
        .iter()
        .map(|a| ChatSource {
            id: a.article.id.clone(),
            title: a.article.title.clone(),
            feed_title: a.feed_title.clone(),
            url: a.article.url.clone(),
            published_at: a.article.published_at,
        })
        .collect();

    Ok(ArticleChatResponse {
        content: response.content,
        provider: provider.name().to_string(),
        model,
        article_ids: selected.iter().map(|a| a.article.id.clone()).collect(),
        sources,
    })
}

#[tauri::command]
pub async fn web_search(query: String) -> Result<Vec<SearchResult>, String> {
    let client = reqwest::Client::builder()
        .user_agent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36")
        .build()
        .map_err(|e| e.to_string())?;

    let url = format!(
        "https://html.duckduckgo.com/html/?q={}",
        urlencoding::encode(&query)
    );

    let html = client
        .get(&url)
        .send()
        .await
        .map_err(|e| format!("Search request failed: {}", e))?
        .text()
        .await
        .map_err(|e| format!("Failed to read search response: {}", e))?;

    Ok(parse_ddg_results(&html))
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
        if results.len() >= 5 {
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
    if text.is_empty() { None } else { Some(text) }
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
