//! xAI (SuperGrok) subscription sign-in — OAuth 2.0 device-code flow (RFC 8628).
//!
//! Same flow BYOS's `grok()` provider offers: the reader opens xAI's
//! verification page, approves, and Skim polls the token endpoint. Device code
//! needs no loopback port, so it works the same on desktop and iOS. auth.x.ai
//! sends no CORS headers, which is why this runs here in Rust and not in the
//! webview.
//!
//! xAI has no public OAuth client for third-party apps; like other BYOS-style
//! tools we use the public Grok CLI client id. xAI may answer 403 for some
//! SuperGrok tiers even after a successful sign-in — the API key path stays
//! available as the fallback.

use super::claude_oauth::TokenSet;
use serde::{Deserialize, Serialize};
use std::time::{Duration, Instant};

pub const CLIENT_ID: &str = "b1a00492-073a-47ea-816f-4c329264a828";
pub const DEVICE_CODE_URL: &str = "https://auth.x.ai/oauth2/device/code";
pub const TOKEN_URL: &str = "https://auth.x.ai/oauth2/token";
pub const SCOPE: &str = "openid profile email offline_access grok-cli:access api:access";
const DEVICE_CODE_GRANT: &str = "urn:ietf:params:oauth:grant-type:device_code";

pub const ACCESS_TOKEN_KEY: &str = "xai_oauth_access_token";
pub const REFRESH_TOKEN_KEY: &str = "xai_oauth_refresh_token";
pub const EXPIRES_AT_KEY: &str = "xai_oauth_expires_at";

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceStart {
    pub device_code: String,
    pub user_code: String,
    pub verification_uri: String,
    pub verification_uri_complete: String,
    pub interval: u64,
    pub expires_in: u64,
}

#[derive(Deserialize)]
struct DeviceCodeResponse {
    device_code: String,
    user_code: String,
    verification_uri: String,
    verification_uri_complete: Option<String>,
    interval: Option<u64>,
    expires_in: Option<u64>,
}

#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
    refresh_token: Option<String>,
    expires_in: Option<i64>,
}

#[derive(Deserialize, Default)]
struct OAuthError {
    error: Option<String>,
    error_description: Option<String>,
}

fn client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(20))
        .build()
        .map_err(|e| e.to_string())
}

pub async fn begin_device() -> Result<DeviceStart, String> {
    let resp = client()?
        .post(DEVICE_CODE_URL)
        .header("Accept", "application/json")
        .form(&[("client_id", CLIENT_ID), ("scope", SCOPE)])
        .send()
        .await
        .map_err(|e| format!("Could not reach xAI sign-in: {e}"))?;
    let status = resp.status();
    let text = resp.text().await.unwrap_or_default();
    if !status.is_success() {
        return Err(format!("xAI sign-in failed to start ({}): {}", status.as_u16(), truncate(&text)));
    }
    let d: DeviceCodeResponse =
        serde_json::from_str(&text).map_err(|_| "xAI returned an unexpected sign-in response".to_string())?;
    Ok(DeviceStart {
        verification_uri_complete: d.verification_uri_complete.unwrap_or_else(|| d.verification_uri.clone()),
        device_code: d.device_code,
        user_code: d.user_code,
        verification_uri: d.verification_uri,
        interval: d.interval.unwrap_or(5).max(1),
        expires_in: d.expires_in.unwrap_or(300),
    })
}

/// Polls until the reader approves, declines, or the code expires.
pub async fn poll_device(device_code: &str, interval: u64, expires_in: u64) -> Result<TokenSet, String> {
    let http = client()?;
    let deadline = Instant::now() + Duration::from_secs(expires_in.min(900));
    let mut wait = Duration::from_secs(interval.max(1));
    while Instant::now() < deadline {
        tokio::time::sleep(wait).await;
        let resp = http
            .post(TOKEN_URL)
            .header("Accept", "application/json")
            .form(&[
                ("grant_type", DEVICE_CODE_GRANT),
                ("client_id", CLIENT_ID),
                ("device_code", device_code),
            ])
            .send()
            .await
            .map_err(|e| format!("Could not reach xAI sign-in: {e}"))?;
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        if status.is_success() {
            return parse_tokens(&text, None);
        }
        let err: OAuthError = serde_json::from_str(&text).unwrap_or_default();
        match err.error.as_deref() {
            Some("authorization_pending") => continue,
            Some("slow_down") => wait += Duration::from_secs(5),
            Some("access_denied") | Some("authorization_denied") => {
                return Err("xAI sign-in was declined".to_string())
            }
            Some("expired_token") => return Err("The xAI sign-in code expired. Start again.".to_string()),
            _ => {
                let detail = err.error_description.or(err.error).unwrap_or_else(|| truncate(&text));
                return Err(format!("xAI sign-in failed ({}): {}", status.as_u16(), detail));
            }
        }
    }
    Err("Timed out waiting for xAI sign-in".to_string())
}

pub async fn refresh_access_token(refresh_token: &str) -> Result<TokenSet, String> {
    let resp = client()?
        .post(TOKEN_URL)
        .header("Accept", "application/json")
        .form(&[
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh_token),
            ("client_id", CLIENT_ID),
        ])
        .send()
        .await
        .map_err(|e| format!("xAI refresh request failed: {e}"))?;
    let status = resp.status();
    let text = resp.text().await.unwrap_or_default();
    if !status.is_success() {
        return Err(format!("xAI token refresh failed ({}): {}", status.as_u16(), truncate(&text)));
    }
    parse_tokens(&text, Some(refresh_token))
}

fn parse_tokens(text: &str, previous_refresh: Option<&str>) -> Result<TokenSet, String> {
    let t: TokenResponse =
        serde_json::from_str(text).map_err(|_| "xAI token response was malformed".to_string())?;
    if t.access_token.is_empty() {
        return Err("xAI token response missing access_token".to_string());
    }
    let expires_in = t.expires_in.filter(|s| *s > 0).unwrap_or(3600);
    Ok(TokenSet {
        access_token: t.access_token,
        refresh_token: t.refresh_token.filter(|r| !r.is_empty()).or(previous_refresh.map(String::from)),
        expires_at: chrono::Utc::now().timestamp() + expires_in,
    })
}

fn truncate(s: &str) -> String {
    let s = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if s.chars().count() > 200 {
        format!("{}…", s.chars().take(200).collect::<String>())
    } else {
        s
    }
}

/// The stored xAI sign-in token, or None when signed out.
pub fn stored_access_token(db: &crate::db::Database) -> Option<String> {
    let conn = db.conn.lock().ok()?;
    let tok = crate::db::queries::get_setting(&conn, ACCESS_TOKEN_KEY).ok().flatten()?;
    if tok.is_empty() { None } else { Some(tok) }
}

pub fn persist_tokens(db: &crate::db::Database, tokens: &TokenSet) -> Result<(), String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    let set = |k: &str, v: &str| crate::db::queries::set_setting(&conn, k, v).map_err(|e| e.to_string());
    set(ACCESS_TOKEN_KEY, &tokens.access_token)?;
    if let Some(rt) = &tokens.refresh_token {
        set(REFRESH_TOKEN_KEY, rt)?;
    }
    set(EXPIRES_AT_KEY, &tokens.expires_at.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refresh_keeps_previous_refresh_token_when_omitted() {
        let t = parse_tokens(r#"{"access_token":"a","expires_in":60}"#, Some("r1")).unwrap();
        assert_eq!(t.access_token, "a");
        assert_eq!(t.refresh_token.as_deref(), Some("r1"));
        assert!(t.expires_at > chrono::Utc::now().timestamp());
    }

    #[test]
    fn missing_access_token_is_an_error() {
        assert!(parse_tokens(r#"{"access_token":""}"#, None).is_err());
    }
}
