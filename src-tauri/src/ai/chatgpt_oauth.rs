//! Sign in with ChatGPT — OpenAI's official way for an open-source app to run on a
//! reader's ChatGPT Plus/Pro plan ("ChatGPT plan usage",
//! https://developers.openai.com/siwc/token-sharing-open-source).
//!
//! Authorization Code + PKCE against auth.openai.com with a loopback callback on
//! `127.0.0.1` (OpenAI refuses `localhost`). The first sign-in registers Skim as the
//! reader's own agent with `client_id=dynamic_agent_client` plus a per-install host
//! id; the callback returns the issued client id, which later sign-ins and every
//! refresh use. Inference goes to the public Responses API (`chatgpt_provider` in
//! `provider.rs`). The iOS app does the same in `NativeChatGPT.swift`.

use super::claude_oauth::TokenSet;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use rand::RngCore;
use sha2::{Digest, Sha256};
use std::net::Ipv4Addr;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

pub const ISSUER: &str = "https://auth.openai.com";
pub const AUTHORIZE_URL: &str = "https://auth.openai.com/api/accounts/authorize";
pub const TOKEN_URL: &str = "https://auth.openai.com/api/accounts/oauth/token";
pub const RESOURCE: &str = "https://api.openai.com/v1";
pub const REGISTRATION_CLIENT_ID: &str = "dynamic_agent_client";
pub const SCOPE: &str = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct";
pub const PLAN_USAGE_SCOPE: &str = "chatgpt.tokens.use.direct";
pub const AGENT_NAME: &str = "Skim";
pub const CALLBACK_PORTS: [u16; 2] = [1455, 54321];
pub const CALLBACK_PATH: &str = "/auth/callback";

pub const ACCESS_TOKEN_KEY: &str = "chatgpt_oauth_access_token";
pub const REFRESH_TOKEN_KEY: &str = "chatgpt_oauth_refresh_token";
pub const EXPIRES_AT_KEY: &str = "chatgpt_oauth_expires_at";
pub const ID_TOKEN_KEY: &str = "chatgpt_oauth_id_token";
pub const EMAIL_KEY: &str = "chatgpt_oauth_email";
/// Kept through sign-out: the registration belongs to the reader's account.
pub const CLIENT_ID_KEY: &str = "chatgpt_oauth_client_id";
/// This install's `ext_agent_host_id`, made once.
pub const HOST_ID_KEY: &str = "chatgpt_oauth_host_id";

#[derive(Debug, Clone)]
pub struct SignInFlow {
    pub authorize_url: String,
    pub state: String,
    pub nonce: String,
    pub verifier: String,
    pub redirect_uri: String,
    pub saved_client_id: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ChatGptTokens {
    pub tokens: TokenSet,
    pub id_token: Option<String>,
    pub scope: Option<String>,
}

pub fn redirect_uri(port: u16) -> String {
    format!("http://127.0.0.1:{port}{CALLBACK_PATH}")
}

pub fn begin_flow(port: u16, saved_client_id: Option<&str>, host_id: &str) -> SignInFlow {
    let verifier = random_url_safe(32);
    let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
    let state = random_url_safe(24);
    let nonce = random_url_safe(24);
    let redirect = redirect_uri(port);
    let client_id = saved_client_id.unwrap_or(REGISTRATION_CLIENT_ID);
    let mut params = vec![
        ("response_type", "code"),
        ("client_id", client_id),
        ("redirect_uri", redirect.as_str()),
        ("scope", SCOPE),
        ("resource", RESOURCE),
        ("state", state.as_str()),
        ("nonce", nonce.as_str()),
        ("code_challenge", challenge.as_str()),
        ("code_challenge_method", "S256"),
        // Every sign-in names this install, returning ones included.
        ("ext_agent_host_id", host_id),
    ];
    if saved_client_id.is_none() {
        params.push(("agent_name_hint", AGENT_NAME));
    }
    let query = params
        .iter()
        .map(|(k, v)| format!("{k}={}", urlencoding::encode(v)))
        .collect::<Vec<_>>()
        .join("&");
    SignInFlow {
        authorize_url: format!("{AUTHORIZE_URL}?{query}"),
        state,
        nonce,
        verifier,
        redirect_uri: redirect,
        saved_client_id: saved_client_id.map(String::from),
    }
}

/// The code and client id from the callback's request target, after checking `state`.
pub fn parse_callback(target: &str, flow: &SignInFlow) -> Result<(String, String), String> {
    let query = target.split_once('?').map(|(_, q)| q).unwrap_or("");
    let value = |name: &str| {
        query.split('&').find_map(|pair| {
            let (k, v) = pair.split_once('=')?;
            (k == name).then(|| urlencoding::decode(v).map(|c| c.into_owned()).unwrap_or_default())
        })
        .filter(|v| !v.is_empty())
    };
    if value("state").as_deref() != Some(flow.state.as_str()) {
        return Err("ChatGPT sign-in didn't match. Start again.".into());
    }
    if let Some(error) = value("error") {
        if error == "access_denied" {
            return Err("ChatGPT sign-in was cancelled.".into());
        }
        return Err(format!("ChatGPT sign-in failed: {}", value("error_description").unwrap_or(error)));
    }
    let code = value("code").ok_or("ChatGPT didn't finish signing in. Start again.")?;
    let issued = value("client_id");
    if let (Some(issued), Some(saved)) = (&issued, &flow.saved_client_id) {
        if issued != saved {
            return Err("ChatGPT sign-in didn't match. Start again.".into());
        }
    }
    let client_id = issued
        .or_else(|| flow.saved_client_id.clone())
        .filter(|id| id != REGISTRATION_CLIENT_ID)
        .ok_or("ChatGPT didn't return a client id. Sign in again.")?;
    Ok((code, client_id))
}

/// Desktop sign-in: listen on the loopback port, open the browser, wait for the
/// redirect, exchange the code. Returns the tokens and the issued client id.
pub async fn run_sign_in(saved_client_id: Option<String>, host_id: &str) -> Result<(ChatGptTokens, String), String> {
    let mut bound = None;
    for port in CALLBACK_PORTS {
        if let Ok(listener) = TcpListener::bind((Ipv4Addr::LOCALHOST, port)).await {
            bound = Some((listener, port));
            break;
        }
    }
    let (listener, port) = bound.ok_or("Couldn't start ChatGPT sign-in: ports 1455 and 54321 are busy.")?;
    let flow = begin_flow(port, saved_client_id.as_deref(), host_id);
    super::claude_oauth::open_browser(&flow.authorize_url)?;
    let target = tokio::select! {
        waited = tokio::time::timeout(Duration::from_secs(600), accept_callback(&listener)) => {
            waited.map_err(|_| "Timed out waiting for ChatGPT sign-in".to_string())??
        }
        _ = cancel_signal().notified() => return Err(CANCELLED.into()),
    };
    let (code, client_id) = parse_callback(&target, &flow)?;
    let tokens = exchange_code(&code, &client_id, &flow).await.map_err(|e| match e {
        TokenError::Rejected(_) => REJECTED.to_string(),
        TokenError::Other(message) => message,
    })?;
    Ok((tokens, client_id))
}

pub const CANCELLED: &str = "ChatGPT sign-in was cancelled.";
/// The code exchange was refused (`invalid_grant` / `invalid_client`). The
/// caller forgets the saved registration so the next sign-in registers afresh.
pub const REJECTED: &str = "ChatGPT didn't accept that sign-in. Sign in again.";

/// A token endpoint failure: `Rejected` when the grant or client is unusable.
#[derive(Debug)]
pub enum TokenError {
    Rejected(String),
    Other(String),
}

impl std::fmt::Display for TokenError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TokenError::Rejected(m) | TokenError::Other(m) => f.write_str(m),
        }
    }
}

fn cancel_signal() -> &'static tokio::sync::Notify {
    static SIGNAL: std::sync::OnceLock<tokio::sync::Notify> = std::sync::OnceLock::new();
    SIGNAL.get_or_init(tokio::sync::Notify::new)
}

/// Stops a sign-in that is waiting for the browser, freeing its port.
pub fn cancel_sign_in() {
    cancel_signal().notify_waiters();
}

async fn accept_callback(listener: &TcpListener) -> Result<String, String> {
    loop {
        let (mut stream, _) = listener.accept().await.map_err(|e| e.to_string())?;
        let mut buf = [0u8; 8192];
        let n = match tokio::time::timeout(Duration::from_secs(5), stream.read(&mut buf)).await {
            Ok(Ok(n)) => n,
            _ => continue,
        };
        let req = String::from_utf8_lossy(&buf[..n]);
        let target = req.lines().next().and_then(|l| l.split_whitespace().nth(1)).unwrap_or("").to_string();
        if target.split('?').next() != Some(CALLBACK_PATH) {
            let _ = stream.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await;
            continue;
        }
        let body = "<html><body style='font-family:system-ui;padding:48px;text-align:center'><h2>Signed in to ChatGPT</h2><p>You can close this window and return to Skim.</p></body></html>";
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        );
        let _ = stream.write_all(response.as_bytes()).await;
        let _ = stream.shutdown().await;
        return Ok(target);
    }
}

async fn exchange_code(code: &str, client_id: &str, flow: &SignInFlow) -> Result<ChatGptTokens, TokenError> {
    let text = post_form(&[
        ("grant_type", "authorization_code"),
        ("client_id", client_id),
        ("code", code),
        ("code_verifier", &flow.verifier),
        ("redirect_uri", &flow.redirect_uri),
        ("resource", RESOURCE),
    ])
    .await?;
    let tokens = parse_tokens(&text, None).map_err(TokenError::Other)?;
    validate(&tokens, client_id, &flow.nonce, chrono::Utc::now().timestamp()).map_err(TokenError::Other)?;
    Ok(tokens)
}

pub async fn refresh_access_token(refresh_token: &str, client_id: &str) -> Result<ChatGptTokens, String> {
    let text = post_form(&[
        ("grant_type", "refresh_token"),
        ("client_id", client_id),
        ("refresh_token", refresh_token),
        ("resource", RESOURCE),
    ])
    .await
    .map_err(|e| e.to_string())?;
    parse_tokens(&text, Some(refresh_token))
}

async fn post_form(fields: &[(&str, &str)]) -> Result<String, TokenError> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .map_err(|e| TokenError::Other(e.to_string()))?;
    let resp = client
        .post(TOKEN_URL)
        .header("Accept", "application/json")
        .form(fields)
        .send()
        .await
        .map_err(|e| TokenError::Other(format!("Could not reach ChatGPT sign-in: {e}")))?;
    let status = resp.status();
    let text = resp.text().await.unwrap_or_default();
    if status.is_success() {
        return Ok(text);
    }
    let v: serde_json::Value = serde_json::from_str(&text).unwrap_or_default();
    let error = v.get("error").and_then(|e| e.as_str()).unwrap_or("");
    let detail = v.get("error_description").and_then(|e| e.as_str()).filter(|d| !d.is_empty()).unwrap_or(error);
    let message = format!("ChatGPT sign-in failed ({}): {}", status.as_u16(), if detail.is_empty() { "no detail" } else { detail });
    log::warn!("{message}");
    Err(if matches!(error, "invalid_grant" | "invalid_client") {
        TokenError::Rejected(message)
    } else {
        TokenError::Other(message)
    })
}

pub fn parse_tokens(text: &str, previous_refresh: Option<&str>) -> Result<ChatGptTokens, String> {
    let v: serde_json::Value =
        serde_json::from_str(text).map_err(|_| "ChatGPT returned an unexpected sign-in response".to_string())?;
    let str_field = |k: &str| v.get(k).and_then(|x| x.as_str()).filter(|s| !s.is_empty()).map(String::from);
    let access_token = str_field("access_token").ok_or("ChatGPT sign-in response had no access token")?;
    let expires_in = v.get("expires_in").and_then(|x| x.as_i64()).filter(|s| *s > 0).unwrap_or(3600);
    Ok(ChatGptTokens {
        tokens: TokenSet {
            access_token,
            refresh_token: str_field("refresh_token").or(previous_refresh.map(String::from)),
            expires_at: chrono::Utc::now().timestamp() + expires_in,
        },
        id_token: str_field("id_token"),
        scope: str_field("scope"),
    })
}

/// The payload of a JWT, without checking its signature.
pub fn jwt_claims(token: &str) -> Option<serde_json::Value> {
    let payload = token.split('.').nth(1)?;
    let bytes = URL_SAFE_NO_PAD.decode(payload.trim_end_matches('=')).ok()?;
    serde_json::from_slice(&bytes).ok()
}

/// Checks the ID token's issuer, audience, nonce, and expiry, and that the reader
/// granted plan usage. The ID token comes straight from OpenAI's token endpoint over
/// TLS, which OpenID Connect Core 3.1.3.7 accepts in place of a signature check.
pub fn validate(tokens: &ChatGptTokens, client_id: &str, nonce: &str, now: i64) -> Result<(), String> {
    let claims = tokens
        .id_token
        .as_deref()
        .and_then(jwt_claims)
        .ok_or("ChatGPT didn't confirm who signed in. Sign in again.")?;
    let aud_ok = match claims.get("aud") {
        Some(serde_json::Value::String(a)) => a == client_id,
        Some(serde_json::Value::Array(list)) => list.iter().any(|a| a.as_str() == Some(client_id)),
        _ => false,
    };
    let iss_ok = claims.get("iss").and_then(|i| i.as_str()).map(|i| i.trim_end_matches('/')) == Some(ISSUER);
    let nonce_ok = claims.get("nonce").and_then(|n| n.as_str()) == Some(nonce);
    let exp_ok = claims.get("exp").and_then(|e| e.as_f64()).map(|e| e as i64 > now - 60).unwrap_or(false);
    if !(aud_ok && iss_ok && nonce_ok && exp_ok) {
        return Err("ChatGPT's sign-in didn't check out. Sign in again.".into());
    }
    let granted = tokens.scope.clone().or_else(|| {
        jwt_claims(&tokens.tokens.access_token)?.get("scope")?.as_str().map(String::from)
    });
    let has_plan_usage = granted
        .unwrap_or_default()
        .split([' ', '+'])
        .any(|s| s == PLAN_USAGE_SCOPE);
    if !has_plan_usage {
        return Err("ChatGPT signed you in but didn't allow Skim to use your plan. Sign in again and allow plan usage.".into());
    }
    Ok(())
}

fn random_url_safe(n: usize) -> String {
    let mut bytes = vec![0u8; n];
    rand::thread_rng().fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(&bytes)
}

// ── Storage ─────────────────────────────────────────────────────────────────

fn get(db: &crate::db::Database, key: &str) -> Option<String> {
    let conn = db.conn.lock().ok()?;
    crate::db::queries::get_setting(&conn, key).ok().flatten().filter(|v| !v.is_empty())
}

pub fn stored_access_token(db: &crate::db::Database) -> Option<String> {
    get(db, ACCESS_TOKEN_KEY)
}

pub fn stored_client_id(db: &crate::db::Database) -> Option<String> {
    get(db, CLIENT_ID_KEY)
}

pub fn stored_email(db: &crate::db::Database) -> Option<String> {
    get(db, EMAIL_KEY)
}

/// This install's host id, made and saved on first use.
pub fn host_id(db: &crate::db::Database) -> Result<String, String> {
    if let Some(id) = get(db, HOST_ID_KEY) {
        return Ok(id);
    }
    let id = format!("urn:uuid:{}", uuid::Uuid::new_v4());
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    crate::db::queries::set_setting(&conn, HOST_ID_KEY, &id).map_err(|e| e.to_string())?;
    Ok(id)
}

pub fn persist(db: &crate::db::Database, tokens: &ChatGptTokens, client_id: &str) -> Result<(), String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    let set = |k: &str, v: &str| crate::db::queries::set_setting(&conn, k, v).map_err(|e| e.to_string());
    set(ACCESS_TOKEN_KEY, &tokens.tokens.access_token)?;
    if let Some(rt) = &tokens.tokens.refresh_token {
        set(REFRESH_TOKEN_KEY, rt)?;
    }
    set(EXPIRES_AT_KEY, &tokens.tokens.expires_at.to_string())?;
    if let Some(id_token) = &tokens.id_token {
        set(ID_TOKEN_KEY, id_token)?;
        if let Some(email) = jwt_claims(id_token).and_then(|c| c.get("email")?.as_str().map(String::from)) {
            set(EMAIL_KEY, &email)?;
        }
    }
    set(CLIENT_ID_KEY, client_id)
}

/// Drops the saved registration, so the next sign-in registers Skim again.
pub fn forget_client_id(db: &crate::db::Database) -> Result<(), String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    crate::db::queries::set_setting(&conn, CLIENT_ID_KEY, "").map_err(|e| e.to_string())
}

/// Signs out: drops the tokens, keeps the host id and the issued client id.
pub fn clear(db: &crate::db::Database) -> Result<(), String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    for key in [ACCESS_TOKEN_KEY, REFRESH_TOKEN_KEY, EXPIRES_AT_KEY, ID_TOKEN_KEY, EMAIL_KEY] {
        crate::db::queries::set_setting(&conn, key, "").map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn jwt(claims: serde_json::Value) -> String {
        format!("e30.{}.sig", URL_SAFE_NO_PAD.encode(claims.to_string()))
    }

    fn query(url: &str, name: &str) -> Option<String> {
        url.split_once('?')?.1.split('&').find_map(|pair| {
            let (k, v) = pair.split_once('=')?;
            (k == name).then(|| urlencoding::decode(v).unwrap().into_owned())
        })
    }

    #[test]
    fn first_sign_in_registers_skim_as_the_readers_agent() {
        let flow = begin_flow(1455, None, "urn:uuid:abc");
        let url = &flow.authorize_url;
        assert!(url.starts_with("https://auth.openai.com/api/accounts/authorize?"));
        assert_eq!(query(url, "client_id").as_deref(), Some("dynamic_agent_client"));
        assert_eq!(query(url, "agent_name_hint").as_deref(), Some("Skim"));
        assert_eq!(query(url, "ext_agent_host_id").as_deref(), Some("urn:uuid:abc"));
        assert_eq!(query(url, "redirect_uri").as_deref(), Some("http://127.0.0.1:1455/auth/callback"));
        assert_eq!(query(url, "scope").as_deref(), Some(SCOPE));
        assert_eq!(query(url, "resource").as_deref(), Some("https://api.openai.com/v1"));
        assert_eq!(query(url, "nonce"), Some(flow.nonce.clone()));
    }

    #[test]
    fn returning_account_reuses_its_client_id() {
        let flow = begin_flow(1455, Some("client-1"), "h");
        assert_eq!(query(&flow.authorize_url, "client_id").as_deref(), Some("client-1"));
        assert_eq!(query(&flow.authorize_url, "agent_name_hint"), None);
        assert_eq!(query(&flow.authorize_url, "ext_agent_host_id").as_deref(), Some("h"));
    }

    #[test]
    fn callback_checks_state_and_takes_the_issued_client_id() {
        let flow = begin_flow(1455, None, "h");
        let ok = format!("/auth/callback?code=c1&state={}&client_id=issued", flow.state);
        assert_eq!(parse_callback(&ok, &flow).unwrap(), ("c1".into(), "issued".into()));
        assert!(parse_callback("/auth/callback?code=c1&state=x&client_id=issued", &flow).is_err());
        let denied = format!("/auth/callback?error=access_denied&state={}", flow.state);
        assert_eq!(parse_callback(&denied, &flow).unwrap_err(), "ChatGPT sign-in was cancelled.");

        let returning = begin_flow(1455, Some("client-1"), "h");
        let omitted = format!("/auth/callback?code=c2&state={}", returning.state);
        assert_eq!(parse_callback(&omitted, &returning).unwrap(), ("c2".into(), "client-1".into()));
        let other = format!("/auth/callback?code=c2&state={}&client_id=client-2", returning.state);
        assert!(parse_callback(&other, &returning).is_err());
    }

    #[test]
    fn sign_in_needs_plan_usage_not_just_identity() {
        let now = chrono::Utc::now().timestamp();
        let id = jwt(serde_json::json!({"iss": "https://auth.openai.com", "aud": "issued", "nonce": "n1", "exp": now + 600}));
        let mut tokens = ChatGptTokens {
            tokens: TokenSet { access_token: "a".into(), refresh_token: Some("r".into()), expires_at: now + 3600 },
            id_token: Some(id),
            scope: Some("chatgpt.tokens.use.direct email offline_access openid profile resource.invoke".into()),
        };
        assert!(validate(&tokens, "issued", "n1", now).is_ok());
        assert!(validate(&tokens, "issued", "other", now).is_err());
        assert!(validate(&tokens, "someone-else", "n1", now).is_err());
        tokens.scope = Some("openid profile email".into());
        assert!(validate(&tokens, "issued", "n1", now).unwrap_err().contains("allow plan usage"));
    }

    #[test]
    fn refresh_keeps_the_old_refresh_token_when_none_comes_back() {
        let t = parse_tokens(r#"{"access_token":"a","expires_in":3600}"#, Some("r1")).unwrap();
        assert_eq!(t.tokens.refresh_token.as_deref(), Some("r1"));
        let t = parse_tokens(r#"{"access_token":"a","refresh_token":"r2"}"#, Some("r1")).unwrap();
        assert_eq!(t.tokens.refresh_token.as_deref(), Some("r2"));
    }
}
