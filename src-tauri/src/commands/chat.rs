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
