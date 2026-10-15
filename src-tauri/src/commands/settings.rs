use crate::commands::ai::SharedSummaryCache;
use crate::db::models::AppSettings;
use crate::db::queries;
use crate::db::Database;
use tauri::State;

#[derive(serde::Serialize, serde::Deserialize)]
pub struct RemoteModel {
    id: String,
    #[serde(default)]
    display_name: String,
}

fn models_url(provider: &str, endpoint: Option<&str>) -> Result<String, String> {
    let base = match provider {
        "openai" => "https://api.openai.com",
        "xai" => "https://api.x.ai",
        "anthropic" => "https://api.anthropic.com",
        "openrouter" => "https://openrouter.ai/api",
        "custom" => endpoint
            .filter(|value| !value.trim().is_empty())
            .ok_or("Set an endpoint before loading models")?,
        _ => return Err("This provider does not offer a model list".into()),
    };
    let base = base.trim().trim_end_matches('/');
    let base = base.strip_suffix("/chat/completions").unwrap_or(base);
    if base.ends_with("/v1") {
        Ok(format!("{base}/models"))
    } else {
        Ok(format!("{base}/v1/models"))
    }
}

/// Id words that mark a model as image, video, audio, embedding or moderation
/// rather than text chat. `/models` lists carry no modality, so the id is all we have.
const NON_CHAT_MODEL_WORDS: &[&str] = &[
    "imagine", "image", "video", "embed", "embedding", "tts", "whisper", "dall", "moderation",
    "transcribe", "sora", "realtime", "audio", "speech",
];

pub(crate) fn is_chat_model(id: &str) -> bool {
    !id.to_ascii_lowercase()
        .split(|c: char| !c.is_ascii_alphanumeric())
        .any(|word| NON_CHAT_MODEL_WORDS.contains(&word))
}

// Use the credentials being edited, without persisting them before Save.
#[tauri::command]
pub async fn list_remote_models(
    provider: String,
    api_key: Option<String>,
    endpoint: Option<String>,
    db: State<'_, Database>,
) -> Result<Vec<RemoteModel>, String> {
    if provider == "chatgpt-subscription" {
        let token = crate::ai::chatgpt_oauth::stored_access_token(&db).ok_or("Sign in with ChatGPT to load models")?;
        let client = reqwest::Client::new();
        return Ok(crate::ai::chatgpt_provider::list_models(&client, &token)
            .await?
            .into_iter()
            .map(|(id, display_name)| RemoteModel { id, display_name })
            .collect());
    }
    // Signed in with SuperGrok and no key typed: list with the sign-in token.
    let api_key = match api_key.filter(|key| !key.trim().is_empty()) {
        None if provider == "xai" => crate::ai::xai_oauth::stored_access_token(&db),
        key => key,
    };
    let url = models_url(&provider, endpoint.as_deref())?;
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|_| "Could not create model-list request")?;
    let mut request = client.get(url);
    if let Some(key) = api_key.as_deref().filter(|key| !key.trim().is_empty()) {
        request = if provider == "anthropic" {
            request
                .header("x-api-key", key.trim())
                .header("anthropic-version", "2023-06-01")
        } else {
            request.bearer_auth(key.trim())
        };
    }
    let response = request
        .send()
        .await
        .map_err(|_| "Could not connect to the model provider")?;
    if !response.status().is_success() {
        return Err(format!(
            "Could not load models (HTTP {}). Check your API key and endpoint.",
            response.status().as_u16()
        ));
    }
    #[derive(serde::Deserialize)]
    struct ModelList {
        data: Vec<RemoteModel>,
    }
    let mut models = response
        .json::<ModelList>()
        .await
        .map_err(|_| "Provider returned an unsupported model list")?
        .data;
    // Keep the provider's own order (Giulio, 2026-10-15): drop only repeats and
    // models that can't answer chat, such as xAI's grok-imagine-* image/video ones.
    let mut seen = std::collections::HashSet::new();
    models.retain(|model| is_chat_model(&model.id) && seen.insert(model.id.clone()));
    for model in &mut models {
        if model.display_name.is_empty() {
            model.display_name = model.id.clone();
        }
    }
    Ok(models)
}

#[cfg(test)]
mod model_list_tests {
    use super::*;
    #[test]
    fn model_endpoints_preserve_custom_api_paths() {
        assert_eq!(
            models_url("openrouter", None).unwrap(),
            "https://openrouter.ai/api/v1/models"
        );
        for endpoint in [
            "https://example.com/api",
            "https://example.com/api/v1/",
            "https://example.com/api/v1/chat/completions",
        ] {
            assert_eq!(
                models_url("custom", Some(endpoint)).unwrap(),
                "https://example.com/api/v1/models"
            );
        }
        assert!(models_url("custom", None).is_err());
        assert!(models_url("none", None).is_err());
    }

    #[test]
    fn non_chat_models_are_hidden() {
        for id in ["grok-4.7", "grok-4.20-0309-reasoning", "grok-build-0.1", "gpt-5", "llama-3.2-11b-vision-instruct"] {
            assert!(is_chat_model(id), "{id}");
        }
        for id in ["grok-imagine-image", "grok-imagine-video-1.5-lite", "dall-e-3", "gpt-image-1", "text-embedding-3-small", "whisper-large-v3", "playai-tts", "omni-moderation-latest"] {
            assert!(!is_chat_model(id), "{id}");
        }
    }
}

#[tauri::command]
pub async fn get_settings(db: State<'_, Database>) -> Result<AppSettings, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    let json = queries::get_setting(&conn, "app_settings").map_err(|e| e.to_string())?;

    match json {
        Some(s) => serde_json::from_str(&s).map_err(|e| e.to_string()),
        None => Ok(AppSettings::default()),
    }
}

#[tauri::command]
pub async fn update_settings(
    db: State<'_, Database>,
    summary_cache: State<'_, SharedSummaryCache>,
    settings: AppSettings,
) -> Result<(), String> {
    // Do all SQLite work in a block so conn is dropped before the await
    let ai_changed = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;

        let old: AppSettings = queries::get_setting(&conn, "app_settings")
            .ok()
            .flatten()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();

        let changed = old.ai.provider != settings.ai.provider
            || old.ai.model != settings.ai.model
            || old.ai.local_model_path != settings.ai.local_model_path
            || old.ai.summary_length != settings.ai.summary_length
            || old.ai.summary_tone != settings.ai.summary_tone
            || old.ai.summary_format != settings.ai.summary_format
            || old.ai.summary_custom_prompt != settings.ai.summary_custom_prompt;

        let json = serde_json::to_string(&settings).map_err(|e| e.to_string())?;
        queries::set_setting(&conn, "app_settings", &json).map_err(|e| e.to_string())?;

        changed
    }; // conn dropped here

    // Release the large DS4 model when neither summaries nor chat use it.
    if settings.ai.provider != "ds4" && settings.ai.chat_provider.as_deref() != Some("ds4") {
        crate::ai::ds4_provider::runtime().stop().await;
    }

    if ai_changed {
        let mut cache = summary_cache.lock().await;
        cache.clear();
    }

    Ok(())
}
