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

// Use the credentials being edited, without persisting them before Save.
#[tauri::command]
pub async fn list_remote_models(
    provider: String,
    api_key: Option<String>,
    endpoint: Option<String>,
) -> Result<Vec<RemoteModel>, String> {
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
    models.sort_by(|a, b| a.id.cmp(&b.id));
    models.dedup_by(|a, b| a.id == b.id);
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

    if ai_changed {
        let mut cache = summary_cache.lock().await;
        cache.clear();
    }

    Ok(())
}
