//! Tauri commands for Sign in with ChatGPT (loopback PKCE flow).

use crate::ai::chatgpt_oauth;
use crate::db::Database;
use tauri::State;

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatGptStatus {
    pub signed_in: bool,
    pub email: Option<String>,
}

/// Opens ChatGPT's sign-in page in the browser and waits for the redirect.
#[tauri::command]
pub async fn chatgpt_oauth_sign_in(db: State<'_, Database>) -> Result<ChatGptStatus, String> {
    let host_id = chatgpt_oauth::host_id(&db)?;
    let saved = chatgpt_oauth::stored_client_id(&db);
    let (tokens, client_id) = chatgpt_oauth::run_sign_in(saved, &host_id).await?;
    chatgpt_oauth::persist(&db, &tokens, &client_id)?;
    Ok(ChatGptStatus { signed_in: true, email: chatgpt_oauth::stored_email(&db) })
}

#[tauri::command]
pub async fn chatgpt_oauth_status(db: State<'_, Database>) -> Result<ChatGptStatus, String> {
    Ok(ChatGptStatus {
        signed_in: chatgpt_oauth::stored_access_token(&db).is_some(),
        email: chatgpt_oauth::stored_email(&db),
    })
}

#[tauri::command]
pub async fn chatgpt_oauth_sign_out(db: State<'_, Database>) -> Result<(), String> {
    chatgpt_oauth::clear(&db)
}
