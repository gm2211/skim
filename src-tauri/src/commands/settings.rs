use crate::commands::ai::SharedSummaryCache;
use crate::db::models::AppSettings;
use crate::db::queries;
use crate::db::Database;
use tauri::State;

#[tauri::command]
pub async fn get_settings(db: State<'_, Database>) -> Result<AppSettings, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    let json = queries::get_setting(&conn, "app_settings")
        .map_err(|e| e.to_string())?;

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
