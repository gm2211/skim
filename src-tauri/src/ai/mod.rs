pub mod provider;
pub mod native_provider;
pub mod ds4_provider;
pub mod prompts;
pub mod publication;
pub mod model_manager;
pub mod claude_oauth;
pub mod xai_oauth;

/// The signed-in subscription token for `provider`: xAI (SuperGrok) for
/// "xai", otherwise Claude Pro/Max. Providers ignore it unless they use it.
pub fn subscription_access_token(db: &crate::db::Database, provider: &str) -> Option<String> {
    match provider {
        "xai" => xai_oauth::stored_access_token(db),
        _ => claude_oauth::stored_access_token(db),
    }
}

/// The refresh token for a signed-in subscription whose access token expires
/// within ten minutes; None when signed out or not yet due.
fn due_refresh_token(db: &crate::db::Database, refresh_key: &str, expires_key: &str) -> Option<String> {
    let conn = db.conn.lock().ok()?;
    let expires_at: i64 = crate::db::queries::get_setting(&conn, expires_key).ok()??.parse().ok()?;
    if expires_at - chrono::Utc::now().timestamp() > 600 {
        return None;
    }
    crate::db::queries::get_setting(&conn, refresh_key).ok()?.filter(|t| !t.is_empty())
}

/// Refreshes Claude and SuperGrok sign-ins shortly before they expire, so a
/// subscription keeps working without signing in again. Run periodically.
pub async fn refresh_due_subscription_tokens(db: &crate::db::Database) {
    if let Some(rt) = due_refresh_token(db, xai_oauth::REFRESH_TOKEN_KEY, xai_oauth::EXPIRES_AT_KEY) {
        match xai_oauth::refresh_access_token(&rt).await {
            Ok(tokens) => {
                if let Err(e) = xai_oauth::persist_tokens(db, &tokens) {
                    log::warn!("Saving refreshed xAI token failed: {e}");
                }
            }
            Err(e) => log::warn!("{e}"),
        }
    }
    if let Some(rt) = due_refresh_token(db, "claude_oauth_refresh_token", "claude_oauth_expires_at") {
        match claude_oauth::refresh_access_token(&rt).await {
            Ok(tokens) => {
                if let Err(e) = crate::commands::claude_oauth::persist_tokens(db, &tokens) {
                    log::warn!("Saving refreshed Claude token failed: {e}");
                }
            }
            Err(e) => log::warn!("{e}"),
        }
    }
}

#[cfg(not(target_os = "ios"))]
pub mod local_provider;

#[cfg(target_os = "ios")]
#[path = "local_provider_ios.rs"]
pub mod local_provider;
