use crate::ai::prompts;
use crate::ai::provider::{ChatMessage, ChatRequest, create_provider};
use crate::db::models::{ArticleFilter, ArticleSummary, Theme};
use crate::db::queries;
use crate::db::Database;
use chrono::Utc;
use serde::Deserialize;
use tauri::State;
use uuid::Uuid;

#[tauri::command]
pub async fn summarize_article(
    db: State<'_, Database>,
    article_id: String,
) -> Result<ArticleSummary, String> {
    // Check for cached summary
    {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        if let Some(existing) = queries::get_article_summary(&conn, &article_id)
            .map_err(|e| e.to_string())?
        {
            return Ok(existing);
        }
    }

    // Get article content and settings
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

    if settings.ai.provider == "none" {
        return Err("No AI provider configured. Go to Settings to set up an AI provider.".to_string());
    }

    let provider = create_provider(
        &settings.ai.provider,
        settings.ai.api_key.as_deref(),
        settings.ai.endpoint.as_deref(),
    )?;

    let model = settings.ai.model.unwrap_or_else(|| "gpt-4o-mini".to_string());
    let text = article.article.content_text.as_deref().unwrap_or("");
    let title = &article.article.title;

    // Get bullet summary
    let bullet_request = ChatRequest {
        model: model.clone(),
        messages: vec![
            ChatMessage {
                role: "system".to_string(),
                content: prompts::article_summary_system_prompt().to_string(),
            },
            ChatMessage {
                role: "user".to_string(),
                content: prompts::article_bullet_summary_prompt(title, text),
            },
        ],
        temperature: Some(0.2),
        max_tokens: Some(512),
    };

    let bullet_response = provider.chat(bullet_request).await?;

    // Get full summary
    let full_request = ChatRequest {
        model: model.clone(),
        messages: vec![
            ChatMessage {
                role: "system".to_string(),
                content: prompts::article_summary_system_prompt().to_string(),
            },
            ChatMessage {
                role: "user".to_string(),
                content: prompts::article_full_summary_prompt(title, text),
            },
        ],
        temperature: Some(0.3),
        max_tokens: Some(1024),
    };

    let full_response = provider.chat(full_request).await?;

    let summary = ArticleSummary {
        article_id: article_id.clone(),
        bullet_summary: Some(bullet_response.content),
        full_summary: Some(full_response.content),
        provider: Some(provider.name().to_string()),
        model: Some(model),
        created_at: Utc::now().timestamp(),
    };

    // Cache it
    {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        queries::insert_article_summary(&conn, &summary).map_err(|e| e.to_string())?;
    }

    Ok(summary)
}

#[derive(Deserialize)]
struct ThemeGroupingResponse {
    themes: Vec<ThemeGroupItem>,
}

#[derive(Deserialize)]
struct ThemeGroupItem {
    label: String,
    summary: String,
    articles: Vec<ThemeArticleRef>,
}

#[derive(Deserialize)]
struct ThemeArticleRef {
    id: String,
    relevance: f64,
}

#[tauri::command]
pub async fn generate_themes(
    db: State<'_, Database>,
) -> Result<Vec<Theme>, String> {
    let (articles, settings_json) = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        let filter = ArticleFilter {
            feed_id: None,
            theme_id: None,
            is_read: Some(false),
            is_starred: None,
            limit: Some(200),
            offset: None,
        };
        let articles = queries::get_articles(&conn, &filter).map_err(|e| e.to_string())?;
        let settings_json = queries::get_setting(&conn, "app_settings").map_err(|e| e.to_string())?;
        (articles, settings_json)
    };

    if articles.is_empty() {
        return Ok(vec![]);
    }

    let settings: crate::db::models::AppSettings = settings_json
        .as_deref()
        .map(|s| serde_json::from_str(s).unwrap_or_default())
        .unwrap_or_default();

    if settings.ai.provider == "none" {
        return Err("No AI provider configured. Go to Settings to set up an AI provider.".to_string());
    }

    let provider = create_provider(
        &settings.ai.provider,
        settings.ai.api_key.as_deref(),
        settings.ai.endpoint.as_deref(),
    )?;

    let model = settings.ai.model.unwrap_or_else(|| "gpt-4o-mini".to_string());

    // Build article snippets for the AI
    let snippets: Vec<serde_json::Value> = articles
        .iter()
        .map(|a| {
            let excerpt = a
                .article
                .content_text
                .as_deref()
                .unwrap_or("")
                .chars()
                .take(300)
                .collect::<String>();
            serde_json::json!({
                "id": a.article.id,
                "title": a.article.title,
                "source": a.feed_title,
                "excerpt": excerpt,
            })
        })
        .collect();

    let articles_json = serde_json::to_string_pretty(&snippets)
        .map_err(|e| e.to_string())?;

    let request = ChatRequest {
        model,
        messages: vec![
            ChatMessage {
                role: "system".to_string(),
                content: prompts::theme_grouping_system_prompt().to_string(),
            },
            ChatMessage {
                role: "user".to_string(),
                content: prompts::theme_grouping_user_prompt(&articles_json),
            },
        ],
        temperature: Some(0.3),
        max_tokens: Some(4096),
    };

    let response = provider.chat(request).await?;

    // Parse the JSON response - try to extract JSON from potential markdown code blocks
    let content = response.content.trim();
    let json_str = if content.starts_with("```") {
        content
            .trim_start_matches("```json")
            .trim_start_matches("```")
            .trim_end_matches("```")
            .trim()
    } else {
        content
    };

    let grouping: ThemeGroupingResponse = serde_json::from_str(json_str)
        .map_err(|e| format!("Failed to parse AI theme response: {}. Response was: {}", e, &content[..content.len().min(200)]))?;

    let now = Utc::now().timestamp();
    let expires_at = now + 6 * 3600; // 6 hours

    // Clear old themes and store new ones
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::clear_themes(&conn).map_err(|e| e.to_string())?;

    let mut result_themes = Vec::new();

    for group in grouping.themes {
        let theme_id = Uuid::new_v4().to_string();
        let article_count = group.articles.len() as i64;
        let theme = Theme {
            id: theme_id.clone(),
            label: group.label,
            summary: Some(group.summary),
            created_at: now,
            expires_at,
            article_count: Some(article_count),
        };

        queries::insert_theme(&conn, &theme).map_err(|e| e.to_string())?;

        for article_ref in &group.articles {
            queries::insert_theme_article(&conn, &theme_id, &article_ref.id, article_ref.relevance)
                .map_err(|e| e.to_string())?;
        }

        result_themes.push(theme);
    }

    Ok(result_themes)
}

#[tauri::command]
pub async fn get_themes(db: State<'_, Database>) -> Result<Vec<Theme>, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::get_themes(&conn).map_err(|e| e.to_string())
}
