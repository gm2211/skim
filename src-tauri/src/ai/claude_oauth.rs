//! Claude Pro/Max OAuth — PKCE flow that yields `sk-ant-oat…` Bearer tokens.
//!
//! We reuse the public Claude Code client_id, which is also what the Claude CLI
//! uses. Endpoints and headers are undocumented but stable across Claude Code
//! versions (cross-checked against the shipped binary strings).
//!
//! Two flow variants:
//!   * `run_oauth_flow_loopback` — desktop: binds a TCP socket on
//!     `127.0.0.1:54134`, opens the browser, intercepts the redirect.
//!   * `begin_paste_flow` / `exchange_pasted_code` — iOS/Tauri-mobile: show
//!     the authorize URL to the user, they complete in the system browser,
//!     copy the displayed `CODE#STATE` string, and paste it back.

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

pub const CLIENT_ID: &str = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
pub const AUTHORIZE_URL: &str = "https://claude.ai/oauth/authorize";
pub const TOKEN_URL: &str = "https://console.anthropic.com/v1/oauth/token";
pub const SCOPE: &str = "user:profile user:inference";
pub const BETA_HEADER: &str = "oauth-2025-04-20,claude-code-20250219";
pub const SYSTEM_PREFIX: &str = "You are Claude Code, Anthropic's official CLI for Claude.";

pub const LOOPBACK_HOST: &str = "127.0.0.1";
pub const LOOPBACK_PORT: u16 = 54134;
pub const LOOPBACK_PATH: &str = "/callback";
pub const PASTE_REDIRECT_URI: &str = "https://console.anthropic.com/oauth/code/callback";

pub fn loopback_redirect_uri() -> String {
    format!("http://{}:{}{}", LOOPBACK_HOST, LOOPBACK_PORT, LOOPBACK_PATH)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TokenSet {
    pub access_token: String,
    pub refresh_token: Option<String>,
    /// Unix seconds.
    pub expires_at: i64,
}

#[derive(Debug, Clone)]
pub struct PkceState {
    pub verifier: String,
    pub challenge: String,
    pub state: String,
    pub redirect_uri: String,
}

pub fn generate_pkce(redirect_uri: &str) -> PkceState {
    let verifier = random_url_safe(32);
    let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
    let state = random_url_safe(32);
    PkceState {
        verifier,
        challenge,
        state,
        redirect_uri: redirect_uri.to_string(),
    }
}

pub fn build_authorize_url(pkce: &PkceState) -> String {
    format!(
        "{}?code=true&client_id={}&response_type=code&redirect_uri={}&scope={}&code_challenge={}&code_challenge_method=S256&state={}",
        AUTHORIZE_URL,
        urlencoding::encode(CLIENT_ID),
        urlencoding::encode(&pkce.redirect_uri),
        urlencoding::encode(SCOPE),
        urlencoding::encode(&pkce.challenge),
        urlencoding::encode(&pkce.state),
    )
}

/// Desktop flow — binds a local TCP listener to intercept the redirect.
pub async fn run_oauth_flow_loopback() -> Result<TokenSet, String> {
    let redirect_uri = loopback_redirect_uri();
    let pkce = generate_pkce(&redirect_uri);
    let auth_url = build_authorize_url(&pkce);

    let listener = TcpListener::bind((LOOPBACK_HOST, LOOPBACK_PORT))
        .await
        .map_err(|e| format!("Bind {}:{} failed ({}) — is another app using this port?", LOOPBACK_HOST, LOOPBACK_PORT, e))?;

    open_browser(&auth_url)?;

    let (code, received_state) = tokio::time::timeout(Duration::from_secs(300), accept_callback(&listener))
        .await
        .map_err(|_| "Timed out waiting for Claude sign-in (5 minutes)".to_string())??;

    if received_state != pkce.state {
        return Err("State mismatch during Claude sign-in".to_string());
    }

    exchange_code(&code, &pkce).await
}

/// Mobile/paste flow — caller shows `authorize_url` to the user, who completes
/// sign-in in the external browser and pastes back the `CODE#STATE` string
/// shown on the console success page.
pub fn begin_paste_flow() -> (String, PkceState) {
    let pkce = generate_pkce(PASTE_REDIRECT_URI);
    let url = build_authorize_url(&pkce);
    (url, pkce)
}

pub async fn exchange_pasted_code(pasted: &str, pkce: &PkceState) -> Result<TokenSet, String> {
    let trimmed = pasted.trim();
    let (code, received_state) = match trimmed.split_once('#') {
        Some((c, s)) => (c.to_string(), s.to_string()),
        None => (trimmed.to_string(), pkce.state.clone()),
    };
    if received_state != pkce.state {
        return Err("State mismatch — please restart sign-in".to_string());
    }
    exchange_code(&code, pkce).await
}

pub async fn refresh_access_token(refresh_token: &str) -> Result<TokenSet, String> {
    let client = reqwest::Client::new();
    let body = serde_json::json!({
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "client_id": CLIENT_ID,
    });
    let resp = client.post(TOKEN_URL)
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("Claude refresh request failed: {}", e))?;
    parse_token_response(resp).await
}

async fn exchange_code(code: &str, pkce: &PkceState) -> Result<TokenSet, String> {
    let client = reqwest::Client::new();
    let body = serde_json::json!({
        "grant_type": "authorization_code",
        "code": code,
        "state": pkce.state,
        "client_id": CLIENT_ID,
        "redirect_uri": pkce.redirect_uri,
        "code_verifier": pkce.verifier,
    });
    let resp = client.post(TOKEN_URL)
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("Claude token request failed: {}", e))?;
    parse_token_response(resp).await
}

async fn parse_token_response(resp: reqwest::Response) -> Result<TokenSet, String> {
    let status = resp.status();
    let text = resp.text().await.map_err(|e| format!("Read token response: {}", e))?;
    if !status.is_success() {
        return Err(format!("Claude token endpoint {}: {}", status, text));
    }
    let v: serde_json::Value = serde_json::from_str(&text)
        .map_err(|e| format!("Parse token JSON: {} — body: {}", e, text))?;
    let access_token = v.get("access_token")
        .and_then(|x| x.as_str())
        .ok_or("Missing access_token in response")?
        .to_string();
    let refresh_token = v.get("refresh_token").and_then(|x| x.as_str()).map(String::from);
    let expires_in = v.get("expires_in").and_then(|x| x.as_i64()).unwrap_or(3600 * 8);
    let expires_at = chrono::Utc::now().timestamp() + expires_in;
    Ok(TokenSet { access_token, refresh_token, expires_at })
}

async fn accept_callback(listener: &TcpListener) -> Result<(String, String), String> {
    let (mut stream, _) = listener.accept().await.map_err(|e| e.to_string())?;
    let mut buf = [0u8; 4096];
    let n = stream.read(&mut buf).await.map_err(|e| e.to_string())?;
    let req = String::from_utf8_lossy(&buf[..n]);
    let line = req.lines().next().unwrap_or("");
    let target = line.split_whitespace().nth(1).unwrap_or("");
    let (code, state) = parse_callback_query(target)?;

    let response_body = "<html><body style='font-family:system-ui;padding:48px;text-align:center'><h2>Signed in to Claude</h2><p>You can close this window and return to Skim.</p></body></html>";
    let response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\n\r\n{}",
        response_body.len(),
        response_body
    );
    let _ = stream.write_all(response.as_bytes()).await;
    let _ = stream.shutdown().await;
    Ok((code, state))
}

fn parse_callback_query(target: &str) -> Result<(String, String), String> {
    let qpos = target.find('?').ok_or("No query in callback")?;
    let query = &target[qpos + 1..];
    let mut code: Option<String> = None;
    let mut state: Option<String> = None;
    for pair in query.split('&') {
        if let Some(eq) = pair.find('=') {
            let k = &pair[..eq];
            let v = urlencoding::decode(&pair[eq + 1..]).map(|c| c.into_owned()).unwrap_or_default();
            match k {
                "code" => code = Some(v),
                "state" => state = Some(v),
                "error" => return Err(format!("Claude OAuth error: {}", v)),
                _ => {}
            }
        }
    }
    Ok((code.ok_or("Missing code")?, state.ok_or("Missing state")?))
}

fn open_browser(url: &str) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open").arg(url).spawn()
            .map_err(|e| format!("open failed: {}", e))?;
        return Ok(());
    }
    #[cfg(target_os = "linux")]
    {
        std::process::Command::new("xdg-open").arg(url).spawn()
            .map_err(|e| format!("xdg-open failed: {}", e))?;
        return Ok(());
    }
    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("cmd").args(["/C", "start", url]).spawn()
            .map_err(|e| format!("start failed: {}", e))?;
        return Ok(());
    }
    #[cfg(target_os = "ios")]
    {
        let _ = url;
        return Err("On iOS, use begin_paste_flow() and let the app open the URL itself".to_string());
    }
}

/// Convenience — read the stored Claude OAuth access token from settings KV.
/// Returns None if missing or empty. Safe to call from any command site.
pub fn stored_access_token(db: &crate::db::Database) -> Option<String> {
    let conn = db.conn.lock().ok()?;
    let tok = crate::db::queries::get_setting(&conn, "claude_oauth_access_token").ok().flatten()?;
    if tok.is_empty() { None } else { Some(tok) }
}

fn random_url_safe(bytes: usize) -> String {
    let mut buf = vec![0u8; bytes];
    rand::thread_rng().fill_bytes(&mut buf);
    URL_SAFE_NO_PAD.encode(&buf)
}
