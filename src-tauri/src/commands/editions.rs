use crate::ai::local_provider::SharedModelState;
use crate::ai::prompts;
use crate::ai::provider::{create_provider_with_app, ChatMessage, ChatRequest};
use crate::commands::ai::{default_model, extract_json_object};
use crate::db::today_edition::{self, TodayEditionItemView, TodayEditionView};
use crate::db::Database;
use crate::db::{queries, story_policy};
use crate::AppHandle;
use serde::{Deserialize, Serialize};
use tauri::{Emitter, State};

#[tauri::command]
pub async fn get_or_generate_today_edition(
    app: AppHandle,
    db: State<'_, Database>,
    model_state: State<'_, SharedModelState>,
    starts_at: i64,
    ends_at: i64,
    generated_at: i64,
    story_limit: i64,
) -> Result<TodayEditionView, String> {
    let (candidates, settings) = {
        let conn = db.conn.lock().map_err(|error| error.to_string())?;
        today_edition::validate_window_and_limit(starts_at, ends_at, generated_at, story_limit)
            .map_err(|error| error.to_string())?;
        let id = today_edition::edition_id(starts_at, ends_at, story_limit);
        if let Some(view) = today_edition::frozen(&conn, &id).map_err(|error| error.to_string())? {
            return Ok(view);
        }
        let candidates =
            today_edition::collect_candidates(&conn, starts_at, ends_at, generated_at, story_limit)
                .map_err(|error| error.to_string())?;
        let settings: crate::db::models::AppSettings = queries::get_setting(&conn, "app_settings")
            .map_err(|error| error.to_string())?
            .as_deref()
            .and_then(|value| serde_json::from_str(value).ok())
            .unwrap_or_default();
        (candidates, settings)
    };
    let fingerprint = today_edition::candidate_fingerprint(&candidates);
    let mut groups = None;
    if settings.ai.provider != "none"
        && crate::db::semantic_edition::eligible_count(candidates.len())
    {
        let mut ai_settings = settings.ai.clone();
        ai_settings.oauth_access_token = crate::ai::claude_oauth::stored_access_token(&db);
        if let Ok(provider) =
            create_provider_with_app(&ai_settings, Some(model_state.inner().clone()), &app)
        {
            let model = ai_settings
                .model
                .clone()
                .unwrap_or_else(|| default_model(&ai_settings.provider));
            groups = crate::db::semantic_edition::plan(
                Some(provider.as_ref()),
                &model,
                today_edition::semantic_listing(&candidates),
                candidates.len(),
            )
            .await;
        }
    }
    let conn = db.conn.lock().map_err(|error| error.to_string())?;
    today_edition::finish_semantic(
        &conn,
        starts_at,
        ends_at,
        generated_at,
        story_limit,
        &fingerprint,
        groups,
    )
    .map_err(|error| error.to_string())
}

#[tauri::command]
pub async fn list_today_edition_items(
    db: State<'_, Database>,
    edition_id: String,
) -> Result<Vec<TodayEditionItemView>, String> {
    let conn = db.conn.lock().map_err(|error| error.to_string())?;
    today_edition::list_items(&conn, &edition_id).map_err(|error| error.to_string())
}

#[tauri::command]
pub async fn set_today_edition_item_consumed(
    db: State<'_, Database>,
    edition_id: String,
    story_id: String,
    is_consumed: bool,
    changed_at: i64,
) -> Result<TodayEditionView, String> {
    let conn = db.conn.lock().map_err(|error| error.to_string())?;
    today_edition::set_item_consumed(&conn, &edition_id, &story_id, is_consumed, changed_at)
        .map_err(|error| error.to_string())
}

// --- Written ledes ----------------------------------------------------------
//
// Semantic planning groups and ranks existing story records before freezing;
// their summaries remain source excerpts. This separate pass writes ledes for stories
// at the top of the page, once per edition, and publishes the page after each
// one so they appear as they land.

pub const TODAY_LEDE_PROGRESS_EVENT: &str = "today_lede_progress";

/// How far down the page ledes are written. Below this, a story is a brief and
/// its own excerpt is the right length already.
const TODAY_LEDE_LIMIT: usize = 6;

#[derive(Serialize, Clone)]
struct TodayLedeProgress {
    edition_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    request_id: Option<String>,
    completed: u32,
    total: u32,
    message: String,
    view: TodayEditionView,
}

fn emit_lede_progress(
    app: &AppHandle,
    edition_id: &str,
    request_id: Option<&str>,
    completed: u32,
    total: u32,
    message: &str,
    view: &TodayEditionView,
) {
    let _ = app.emit(
        TODAY_LEDE_PROGRESS_EVENT,
        TodayLedeProgress {
            edition_id: edition_id.to_string(),
            request_id: request_id.map(str::to_string),
            completed,
            total,
            message: message.to_string(),
            view: view.clone(),
        },
    );
}

/// Writes the missing ledes for an edition's lead stories and returns the page
/// with them in place. Safe to call on every open: stories that already have a
/// lede are skipped, and with no AI provider configured it returns the page
/// untouched rather than failing, because Today has to work without one.
#[tauri::command]
pub async fn generate_today_ledes(
    app: AppHandle,
    db: State<'_, Database>,
    model_state: State<'_, SharedModelState>,
    edition_id: String,
    request_id: Option<String>,
) -> Result<TodayEditionView, String> {
    let (view, settings_json, pending) = {
        let conn = db.conn.lock().map_err(|error| error.to_string())?;
        let view = today_edition::load(&conn, &edition_id).map_err(|error| error.to_string())?;
        let settings_json =
            queries::get_setting(&conn, "app_settings").map_err(|error| error.to_string())?;
        let pending: Vec<(String, String, Vec<String>)> = view
            .items
            .iter()
            .take(TODAY_LEDE_LIMIT)
            .filter(|item| {
                item.snapshot
                    .lede
                    .as_deref()
                    .unwrap_or_default()
                    .trim()
                    .is_empty()
            })
            .map(|item| {
                (
                    item.snapshot.story_id.clone(),
                    item.snapshot.snapshot_title.clone(),
                    item.member_article_ids.clone(),
                )
            })
            .collect();
        (view, settings_json, pending)
    };

    if pending.is_empty() {
        return Ok(view);
    }

    let settings: crate::db::models::AppSettings = settings_json
        .as_deref()
        .map(|value| serde_json::from_str(value).unwrap_or_default())
        .unwrap_or_default();
    if settings.ai.provider == "none" {
        return Ok(view);
    }

    let mut ai_settings = settings.ai.clone();
    ai_settings.oauth_access_token = crate::ai::claude_oauth::stored_access_token(&db);
    let provider = create_provider_with_app(&ai_settings, Some(model_state.inner().clone()), &app)?;
    let model = ai_settings
        .model
        .clone()
        .unwrap_or_else(|| default_model(&ai_settings.provider));

    let total = pending.len() as u32;
    emit_lede_progress(
        &app,
        &edition_id,
        request_id.as_deref(),
        0,
        total,
        &match total {
            1 => "Writing the lead story…".to_string(),
            n => format!("Writing {n} stories…"),
        },
        &view,
    );

    for (index, (story_id, headline, article_ids)) in pending.iter().enumerate() {
        let articles_text = lede_source_text(&db, article_ids).await?;

        if articles_text.trim().is_empty() {
            continue;
        }

        let request = ChatRequest {
            model: model.clone(),
            messages: vec![
                ChatMessage {
                    role: "system".to_string(),
                    content: prompts::catchup_lede_system_prompt(),
                    content_blocks: None,
                },
                ChatMessage {
                    role: "user".to_string(),
                    content: prompts::catchup_lede_user_prompt(headline, &articles_text),
                    content_blocks: None,
                },
            ],
            temperature: Some(0.3),
            max_tokens: Some(300),
            json_mode: true,
            tools: None,
        };

        let lede = match provider.chat(request).await {
            Ok(response) => parse_lede(response.content.trim()),
            // One story failing to write is not worth losing the page over.
            Err(_) => String::new(),
        };

        if !lede.is_empty() {
            let conn = db.conn.lock().map_err(|error| error.to_string())?;
            queries::set_edition_item_lede(&conn, &edition_id, story_id, &lede)
                .map_err(|error| error.to_string())?;
        }

        let updated = {
            let conn = db.conn.lock().map_err(|error| error.to_string())?;
            today_edition::load(&conn, &edition_id).map_err(|error| error.to_string())?
        };
        let completed = index as u32 + 1;
        emit_lede_progress(
            &app,
            &edition_id,
            request_id.as_deref(),
            completed,
            total,
            &format!("Writing story {completed} of {total}…"),
            &updated,
        );
    }

    let final_view = {
        let conn = db.conn.lock().map_err(|error| error.to_string())?;
        today_edition::load(&conn, &edition_id).map_err(|error| error.to_string())?
    };
    emit_lede_progress(&app, &edition_id, request_id.as_deref(), total, total, "", &final_view);
    Ok(final_view)
}

/// Read only this story's selected reports, release the DB lock before network
/// work, and reuse the reader/chat resolver's cache, deadlines, and fallback.
async fn lede_source_text(db: &Database, article_ids: &[String]) -> Result<String, String> {
    let articles = {
        let conn = db.conn.lock().map_err(|error| error.to_string())?;
        article_ids
            .iter()
            .take(story_policy::today_lede_max_articles())
            .map(|id| queries::get_article_by_id(&conn, id).map_err(|error| error.to_string()))
            .collect::<Result<Vec<_>, _>>()?
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
    };
    let sources: Vec<_> = articles
        .iter()
        .map(|article| article.article.clone())
        .collect();
    let bodies = super::article_body::resolve_selected_article_texts(db, &sources).await;
    let mut text = String::new();
    for (article, body) in articles.iter().zip(bodies) {
        let body: String = body
            .chars()
            .take(story_policy::today_lede_text_characters())
            .collect();
        if body.trim().is_empty() {
            continue;
        }
        text.push_str(&format!(
            "--- {} [{}]\n{}\n\n",
            article.article.title.trim(),
            crate::ai::publication::publication_name(
                &article.feed_title,
                article.article.url.as_deref()
            ),
            body.trim()
        ));
    }
    Ok(text)
}

#[derive(Deserialize)]
struct LedeRaw {
    #[serde(default, alias = "summary", alias = "text")]
    lede: String,
}

/// Providers that honour `json_mode` give us an object; the rest give prose.
fn parse_lede(content: &str) -> String {
    if let Some(parsed) = extract_json_object(content)
        .and_then(|json| serde_json::from_str::<LedeRaw>(json).ok())
        .map(|raw| raw.lede.trim().to_string())
        .filter(|lede| !lede.is_empty())
    {
        return parsed;
    }
    if content.starts_with('{') {
        return String::new();
    }
    content.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn lede_evidence_uses_full_reader_and_html_bodies_with_shared_bounds() {
        let db =
            Database::new(std::env::temp_dir().join(format!("skim-lede-{}", uuid::Uuid::new_v4())))
                .unwrap();
        {
            let conn = db.conn.lock().unwrap();
            conn.execute_batch("INSERT INTO feeds (id, title, url, created_at, updated_at) VALUES ('feed', 'News', 'https://feed.test', 0, 0);
                INSERT INTO articles (id, feed_id, title, content_text, content_html, fetched_at) VALUES
                ('cached', 'feed', 'Cached report', 'RSS teaser', NULL, 0),
                ('html', 'feed', 'HTML report', 'Short', '<p>Full feed body with its supporting evidence.</p>', 0),
                ('long', 'feed', 'Long report', NULL, NULL, 0),
                ('empty', 'feed', 'Empty report', NULL, NULL, 0),
                ('excluded', 'feed', 'Excluded report', 'Must not enter evidence', NULL, 0);").unwrap();
            queries::put_reader_cache(
                &conn,
                "cached",
                None,
                "<p>Reader extraction with details absent from RSS.</p>",
                "",
            )
            .unwrap();
            conn.execute(
                "UPDATE articles SET content_text = ?1 WHERE id = 'long'",
                ["é".repeat(story_policy::today_lede_text_characters() + 1)],
            )
            .unwrap();
        }
        let ids = ["cached", "html", "long", "empty", "excluded"].map(str::to_string);
        let text = lede_source_text(&db, &ids).await.unwrap();
        assert!(text.contains("Reader extraction with details absent from RSS."));
        assert!(text.contains("Full feed body with its supporting evidence."));
        assert!(!text.contains("RSS teaser"));
        assert!(!text.contains("Empty report"));
        assert!(!text.contains("Excluded report"));
        assert_eq!(
            text.matches('é').count(),
            story_policy::today_lede_text_characters()
        );
        assert!(text.find("Cached report").unwrap() < text.find("HTML report").unwrap());
    }
}
