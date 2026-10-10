//! Tauri commands for xAI (SuperGrok) subscription sign-in via device code.

use crate::ai::xai_oauth::{self, DeviceStart};
use crate::db::{queries, Database};
use tauri::State;

/// Starts sign-in. The UI shows `userCode` and opens `verificationUriComplete`,
/// then calls `xai_oauth_complete` with the returned device code.
#[tauri::command]
pub async fn xai_oauth_begin() -> Result<DeviceStart, String> {
    xai_oauth::begin_device().await
}

#[tauri::command]
pub async fn xai_oauth_complete(
    device_code: String,
    interval: u64,
    expires_in: u64,
    db: State<'_, Database>,
) -> Result<(), String> {
    let tokens = xai_oauth::poll_device(&device_code, interval, expires_in).await?;
    xai_oauth::persist_tokens(&db, &tokens)
}

#[tauri::command]
pub async fn xai_oauth_status(db: State<'_, Database>) -> Result<bool, String> {
    Ok(xai_oauth::stored_access_token(&db).is_some())
}

#[tauri::command]
pub async fn xai_oauth_sign_out(db: State<'_, Database>) -> Result<(), String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    for key in [xai_oauth::ACCESS_TOKEN_KEY, xai_oauth::REFRESH_TOKEN_KEY, xai_oauth::EXPIRES_AT_KEY] {
        queries::set_setting(&conn, key, "").map_err(|e| e.to_string())?;
    }
    Ok(())
}
