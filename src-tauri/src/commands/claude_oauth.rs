//! Tauri commands for Claude Pro/Max OAuth sign-in.
//!
//! Desktop flow uses a loopback TCP listener and opens the system browser.
//! Paste-code flow is exposed for mobile / constrained environments.

use crate::ai::claude_oauth::{self, PkceState, TokenSet};
use crate::db::{queries, Database};
use std::sync::Mutex;
use tauri::State;

pub struct PasteFlowState(pub Mutex<Option<PkceState>>);

impl Default for PasteFlowState {
    fn default() -> Self {
        Self(Mutex::new(None))
    }
}

#[tauri::command]
pub async fn claude_oauth_sign_in_loopback(db: State<'_, Database>) -> Result<(), String> {
    let tokens = claude_oauth::run_oauth_flow_loopback().await?;
    persist_tokens(&db, &tokens)?;
    Ok(())
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PasteFlowStart {
    pub authorize_url: String,
}

#[tauri::command]
pub async fn claude_oauth_begin_paste(state: State<'_, PasteFlowState>) -> Result<PasteFlowStart, String> {
    let (url, pkce) = claude_oauth::begin_paste_flow();
    let mut guard = state.0.lock().map_err(|e| e.to_string())?;
    *guard = Some(pkce);
    Ok(PasteFlowStart { authorize_url: url })
}

#[tauri::command]
pub async fn claude_oauth_exchange_paste(
    pasted_code: String,
    db: State<'_, Database>,
    state: State<'_, PasteFlowState>,
) -> Result<(), String> {
    let pkce = {
        let mut guard = state.0.lock().map_err(|e| e.to_string())?;
        guard.take().ok_or("No paste flow in progress — begin first")?
    };
    let tokens = claude_oauth::exchange_pasted_code(&pasted_code, &pkce).await?;
    persist_tokens(&db, &tokens)?;
    Ok(())
}

#[tauri::command]
pub async fn claude_oauth_sign_out(db: State<'_, Database>) -> Result<(), String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    for key in ["claude_oauth_access_token", "claude_oauth_refresh_token", "claude_oauth_expires_at"] {
        queries::set_setting(&conn, key, "").map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
pub async fn claude_oauth_refresh(db: State<'_, Database>) -> Result<(), String> {
    let refresh = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        queries::get_setting(&conn, "claude_oauth_refresh_token")
            .map_err(|e| e.to_string())?
            .filter(|t| !t.is_empty())
            .ok_or("No refresh token stored")?
    };
    let tokens = claude_oauth::refresh_access_token(&refresh).await?;
    persist_tokens(&db, &tokens)?;
    Ok(())
}

#[tauri::command]
pub async fn claude_oauth_status(db: State<'_, Database>) -> Result<bool, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    let token = queries::get_setting(&conn, "claude_oauth_access_token").map_err(|e| e.to_string())?;
    Ok(token.map(|t| !t.is_empty()).unwrap_or(false))
}

fn persist_tokens(db: &Database, tokens: &TokenSet) -> Result<(), String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::set_setting(&conn, "claude_oauth_access_token", &tokens.access_token)
        .map_err(|e| e.to_string())?;
    if let Some(rt) = &tokens.refresh_token {
        queries::set_setting(&conn, "claude_oauth_refresh_token", rt)
            .map_err(|e| e.to_string())?;
    }
    queries::set_setting(&conn, "claude_oauth_expires_at", &tokens.expires_at.to_string())
        .map_err(|e| e.to_string())?;
    Ok(())
}
