use crate::ai::local_provider::SharedModelState;
use crate::ai::prompts;
use crate::ai::provider::{create_provider_with_app, AiProvider, ChatMessage, ChatRequest};
use crate::commands::ai::default_model;
use crate::db::today_edition::{self, TodayEditionItemView, TodayEditionView};
use crate::db::Database;
use crate::db::{queries, story_policy};
use crate::AppHandle;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
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
        let evidence = lede_source_text(&db, article_ids).await?;
        let articles_text = &evidence.prompt_text;

        if articles_text.trim().is_empty() {
            continue;
        }

        if let Some(preview) = verified_preview(provider.as_ref(), &model, headline, &evidence).await {
            let conn = db.conn.lock().map_err(|error| error.to_string())?;
            queries::set_verified_edition_item_lede(&conn, &edition_id, story_id, &preview.excerpt,
                &preview.source_article_id, &preview.source_evidence_hash)
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
pub(crate) struct LedeSource {
    article_id: String,
    pub(crate) body: String,
}
pub(crate) struct LedeEvidence {
    prompt_text: String,
    pub(crate) sources: Vec<LedeSource>,
}
#[derive(Debug, PartialEq)]
pub(crate) struct VerifiedPreview {
    pub(crate) excerpt: String,
    source_article_id: String,
    source_evidence_hash: String,
}
impl LedeEvidence {
    fn preview(&self, index: usize, excerpt: String) -> Option<VerifiedPreview> {
        let source = self.sources.get(index)?;
        Some(VerifiedPreview {
            excerpt, source_article_id: source.article_id.clone(),
            source_evidence_hash: format!("{:x}", Sha256::digest(source.body.as_bytes())),
        })
    }
}

pub(crate) async fn lede_source_text(db: &Database, article_ids: &[String]) -> Result<LedeEvidence, String> {
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
    let mut bounded_sources = Vec::new();
    for (article, body) in articles.iter().zip(bodies) {
        let body: String = body
            .trim()
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
        bounded_sources.push(LedeSource { article_id: article.article.id.clone(), body });
    }
    Ok(LedeEvidence { prompt_text: text, sources: bounded_sources })
}

pub(crate) async fn verified_preview(provider: &dyn AiProvider, model: &str, headline: &str, evidence: &LedeEvidence) -> Option<VerifiedPreview> {
    let bodies: Vec<String> = evidence.sources.iter().map(|source| source.body.clone()).collect();
    let make_request = |system: String, user: String, json_mode| ChatRequest {
        model: model.into(), messages: vec![ChatMessage::text("system", system), ChatMessage::text("user", user)],
        temperature: Some(0.0), max_tokens: Some(300), json_mode, tools: None,
    };
    let response = provider.chat(make_request(prompts::catchup_lede_system_prompt(),
        prompts::catchup_lede_user_prompt(headline, &evidence.prompt_text), true)).await.ok()?;
    if let Some((index, excerpt)) = parse_excerpt(&response.content, &bodies) { return evidence.preview(index, excerpt); }
    // One retry for invalid output only. Transport/model errors remain missing,
    // and the entire plaintext reply must still pass the source validator.
    let response = provider.chat(make_request(story_policy::today_lede_retry_prompt().into(),
        prompts::catchup_lede_retry_user_prompt(headline, &evidence.prompt_text), false)).await.ok()?;
    let (index, excerpt) = story_policy::validated_today_excerpt_source(&bodies, &response.content)?;
    evidence.preview(index, excerpt)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ExcerptRaw {
    excerpt: String,
}

fn parse_excerpt(content: &str, bodies: &[String]) -> Option<(usize, String)> {
    let trimmed = content.trim();
    let json = if let Some(body) = trimmed.strip_prefix("```json").or_else(|| trimmed.strip_prefix("```")) {
        body.trim().strip_suffix("```")?.trim()
    } else { trimmed };
    let raw: ExcerptRaw = serde_json::from_str(json).ok()?;
    story_policy::validated_today_excerpt_source(bodies, &raw.excerpt)
}

#[cfg(test)]
mod tests {
    use super::*;

    struct PreviewProvider {
        replies: std::sync::Mutex<std::collections::VecDeque<Result<String, String>>>,
        requests: std::sync::Mutex<Vec<ChatRequest>>,
    }
    #[async_trait::async_trait]
    impl AiProvider for PreviewProvider {
        async fn chat(&self, request: ChatRequest) -> Result<crate::ai::provider::ChatResponse, String> {
            self.requests.lock().unwrap().push(request);
            Ok(crate::ai::provider::ChatResponse {
                content: self.replies.lock().unwrap().pop_front().expect("no third attempt")?,
                model: "test".into(), usage: None, tool_uses: vec![], stop_reason: None,
            })
        }
        fn name(&self) -> &str { "test" }
    }

    #[tokio::test]
    async fn invalid_json_gets_one_source_verified_plaintext_retry_only() {
        let evidence = LedeEvidence { prompt_text: "--- A report\nThe event happened in June.".into(),
            sources: vec![LedeSource { article_id: "article-a".into(), body: "The event happened in June.".into() }] };
        let valid = "The event happened in June.";
        for (replies, expected, calls) in [
            (vec![Ok(serde_json::json!({"excerpt":valid}).to_string())], Some(valid), 1),
            (vec![Ok("{malformed".into()), Ok(format!("  {valid}\n"))], Some(valid), 2),
            (vec![Ok("{malformed".into()), Ok("The event happened in August.".into())], None, 2),
            (vec![Ok("{malformed".into()), Ok(format!("Here is the excerpt: {valid}"))], None, 2),
            (vec![Ok("{malformed".into()), Err("model unavailable".into())], None, 2),
            (vec![Err("model unavailable".into())], None, 1),
        ] {
            let provider = PreviewProvider { replies: std::sync::Mutex::new(replies.into()), requests: Default::default() };
            assert_eq!(verified_preview(&provider, "configured-model", "Headline", &evidence).await.map(|preview| preview.excerpt).as_deref(), expected);
            let requests = provider.requests.lock().unwrap();
            assert_eq!(requests.len(), calls);
            assert!(requests[0].json_mode);
            for request in requests.iter() {
                assert_eq!(request.model, "configured-model");
                assert_eq!(request.temperature, Some(0.0));
                assert_eq!(request.max_tokens, Some(300));
            }
            if calls == 2 {
                assert!(!requests[1].json_mode);
                assert_eq!(requests[1].messages[0].content, story_policy::today_lede_retry_prompt());
                assert_eq!(requests[1].messages[1].content, "Headline: Headline\n\nArticle text behind it:\n--- A report\nThe event happened in June.");
            }
        }
    }

    #[tokio::test]
    async fn preview_preserves_nonrepresentative_source_and_exact_evidence_hash() {
        let body = "The hearing ended on Thursday. The court reserved its decision.";
        let evidence = LedeEvidence { prompt_text: "both sources".into(), sources: vec![
            LedeSource { article_id: "representative".into(), body: "The hearing starts tomorrow.".into() },
            LedeSource { article_id: "outcome".into(), body: body.into() },
        ] };
        let provider = PreviewProvider {
            replies: std::sync::Mutex::new(vec![Ok(serde_json::json!({
                "excerpt":"The hearing ended on Thursday."}).to_string())].into()),
            requests: Default::default(),
        };
        let preview = verified_preview(&provider, "test", "Hearing preview", &evidence).await.unwrap();
        assert_eq!(preview.source_article_id, "outcome");
        assert_eq!(preview.excerpt, "The hearing ended on Thursday.");
        assert_eq!(preview.source_evidence_hash, format!("{:x}", Sha256::digest(body.as_bytes())));
        assert_ne!(preview.source_evidence_hash, format!("{:x}", Sha256::digest(evidence.sources[0].body.as_bytes())));
    }

    #[test]
    fn preview_requires_one_exact_source_passage_and_strict_object() {
        let bodies = vec!["The breach happened in June. OpenAI discovered it in August.".into(),
            "The report did not establish causation. Officials are investigating.".into()];
        assert_eq!(parse_excerpt("```json\n{\"excerpt\":\"The breach  happened\\n in June.\"}\n```", &bodies), Some((0, "The breach happened in June.".into())));
        for excerpt in ["The breach happened in August.", "establish causation.",
            "The breach happened in June. Officials are investigating.", "Headline only."] {
            assert!(parse_excerpt(&serde_json::json!({"excerpt":excerpt}).to_string(), &bodies).is_none(), "{excerpt}");
        }
        for raw in ["The breach happened in June.", "prefix {\"excerpt\":\"The breach happened in June.\"}",
            "{\"lede\":\"The breach happened in June.\"}", "{\"excerpt\":\"The breach happened in June.\",\"other\":true}"] {
            assert!(parse_excerpt(raw, &bodies).is_none(), "{raw}");
        }
        let long = format!("{}ends.", "word ".repeat(61));
        assert!(parse_excerpt(&serde_json::json!({"excerpt":long}).to_string(), &[long]).is_none());
    }

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
        let evidence = lede_source_text(&db, &ids).await.unwrap();
        assert_eq!(evidence.sources.len(), 3);
        assert_eq!(evidence.sources.iter().map(|s| s.article_id.as_str()).collect::<Vec<_>>(), vec!["cached", "html", "long"]);
        let sparse = lede_source_text(&db, &["missing".into(), "empty".into(), "html".into(), "cached".into()]).await.unwrap();
        assert_eq!(sparse.sources.iter().map(|source| source.article_id.as_str()).collect::<Vec<_>>(), vec!["html", "cached"]);
        let text = evidence.prompt_text;
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
