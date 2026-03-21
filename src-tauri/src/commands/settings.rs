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
    settings: AppSettings,
) -> Result<(), String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    let json = serde_json::to_string(&settings).map_err(|e| e.to_string())?;
    queries::set_setting(&conn, "app_settings", &json).map_err(|e| e.to_string())
}
