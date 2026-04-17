use serde::{Deserialize, Serialize};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use uuid::Uuid;

const FEEDLY_AUTH_URL: &str = "https://cloud.feedly.com/v3/auth/auth";
const FEEDLY_TOKEN_URL: &str = "https://cloud.feedly.com/v3/auth/token";
const FEEDLY_SCOPE: &str = "https://cloud.feedly.com/subscriptions";
const REDIRECT_HOST: &str = "127.0.0.1";
const REDIRECT_PORT: u16 = 54321;
const REDIRECT_PATH: &str = "/feedly/callback";

pub fn redirect_uri() -> String {
    format!("http://{}:{}{}", REDIRECT_HOST, REDIRECT_PORT, REDIRECT_PATH)
}

/// Returns baked-in client credentials from build-time env vars, if present.
/// Set FEEDLY_CLIENT_ID / FEEDLY_CLIENT_SECRET at compile time to embed.
pub fn baked_credentials() -> Option<(String, String)> {
    match (option_env!("FEEDLY_CLIENT_ID"), option_env!("FEEDLY_CLIENT_SECRET")) {
        (Some(id), Some(secret)) if !id.is_empty() && !secret.is_empty() => {
            Some((id.to_string(), secret.to_string()))
        }
        _ => None,
    }
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct TokenResponse {
    pub access_token: String,
    #[serde(default)]
    pub refresh_token: Option<String>,
    #[serde(default)]
    pub expires_in: Option<i64>,
    pub token_type: String,
    #[serde(default)]
    pub id: Option<String>,
    #[serde(default)]
    pub plan: Option<String>,
}

struct CallbackResult {
    code: String,
    state: String,
}

pub async fn run_oauth_flow(
    client_id: &str,
    client_secret: &str,
) -> Result<TokenResponse, String> {
    let state = Uuid::new_v4().to_string();
    let redirect_uri = redirect_uri();

    let listener = TcpListener::bind((REDIRECT_HOST, REDIRECT_PORT))
        .await
        .map_err(|e| {
            format!(
                "Failed to bind {}:{} — is another app using this port? ({})",
                REDIRECT_HOST, REDIRECT_PORT, e
            )
        })?;

    let auth_url = format!(
        "{}?response_type=code&client_id={}&redirect_uri={}&scope={}&state={}",
        FEEDLY_AUTH_URL,
        urlencoding::encode(client_id),
        urlencoding::encode(&redirect_uri),
        urlencoding::encode(FEEDLY_SCOPE),
        urlencoding::encode(&state),
    );

    open_browser(&auth_url)?;

    let callback = tokio::time::timeout(Duration::from_secs(300), accept_callback(&listener))
        .await
        .map_err(|_| "Timed out waiting for Feedly login (5 minutes)".to_string())??;

    if callback.state != state {
        return Err("State mismatch — possible CSRF; please retry".to_string());
    }

    exchange_code(client_id, client_secret, &callback.code, &redirect_uri).await
}

pub async fn refresh_access_token(
    client_id: &str,
    client_secret: &str,
    refresh_token: &str,
) -> Result<TokenResponse, String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .map_err(|e| format!("HTTP client error: {}", e))?;

    let params = [
        ("refresh_token", refresh_token),
        ("client_id", client_id),
        ("client_secret", client_secret),
        ("grant_type", "refresh_token"),
    ];

    let response = client
        .post(FEEDLY_TOKEN_URL)
        .form(&params)
        .send()
        .await
        .map_err(|e| format!("Token refresh failed: {}", e))?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        return Err(format!("Feedly token refresh error ({}): {}", status, body));
    }

    response
        .json::<TokenResponse>()
        .await
        .map_err(|e| format!("Failed to parse token response: {}", e))
}

async fn exchange_code(
    client_id: &str,
    client_secret: &str,
    code: &str,
    redirect_uri: &str,
) -> Result<TokenResponse, String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .map_err(|e| format!("HTTP client error: {}", e))?;

    let params = [
        ("code", code),
        ("client_id", client_id),
        ("client_secret", client_secret),
        ("redirect_uri", redirect_uri),
        ("grant_type", "authorization_code"),
    ];

    let response = client
        .post(FEEDLY_TOKEN_URL)
        .form(&params)
        .send()
        .await
        .map_err(|e| format!("Token exchange failed: {}", e))?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        return Err(format!("Feedly token exchange error ({}): {}", status, body));
    }

    response
        .json::<TokenResponse>()
        .await
        .map_err(|e| format!("Failed to parse token response: {}", e))
}

async fn accept_callback(listener: &TcpListener) -> Result<CallbackResult, String> {
    loop {
        let (mut stream, _) = listener
            .accept()
            .await
            .map_err(|e| format!("Accept failed: {}", e))?;

        let mut buf = vec![0u8; 8192];
        let n = stream
            .read(&mut buf)
            .await
            .map_err(|e| format!("Read failed: {}", e))?;
        let request = String::from_utf8_lossy(&buf[..n]);

        let first_line = request.lines().next().unwrap_or("");
        let path = first_line.split_whitespace().nth(1).unwrap_or("");

        if !path.starts_with(REDIRECT_PATH) {
            let _ = write_response(&mut stream, 404, "Not Found", "Not Found").await;
            continue;
        }

        let query = path.split('?').nth(1).unwrap_or("");
        let mut code: Option<String> = None;
        let mut state: Option<String> = None;
        let mut error: Option<String> = None;
        for pair in query.split('&') {
            let mut it = pair.splitn(2, '=');
            let k = it.next().unwrap_or("");
            let v = it.next().unwrap_or("");
            let decoded = urlencoding::decode(v).map(|s| s.into_owned()).unwrap_or_default();
            match k {
                "code" => code = Some(decoded),
                "state" => state = Some(decoded),
                "error" => error = Some(decoded),
                _ => {}
            }
        }

        if let Some(err) = error {
            let html = format!(
                "<html><body style='font-family:sans-serif;padding:40px;text-align:center;'>\
                 <h2>Feedly login failed</h2><p>{}</p><p>You can close this window.</p></body></html>",
                html_escape(&err)
            );
            let _ = write_response(&mut stream, 200, "OK", &html).await;
            return Err(format!("Feedly returned error: {}", err));
        }

        match (code, state) {
            (Some(code), Some(state)) => {
                let html = "<html><body style='font-family:sans-serif;padding:40px;text-align:center;'>\
                     <h2>Feedly connected</h2><p>You can close this window and return to Skim.</p>\
                     <script>setTimeout(()=>window.close(),500)</script></body></html>";
                let _ = write_response(&mut stream, 200, "OK", html).await;
                return Ok(CallbackResult { code, state });
            }
            _ => {
                let _ = write_response(&mut stream, 400, "Bad Request", "Missing code").await;
                continue;
            }
        }
    }
}

async fn write_response(
    stream: &mut tokio::net::TcpStream,
    status: u16,
    status_text: &str,
    body: &str,
) -> std::io::Result<()> {
    let response = format!(
        "HTTP/1.1 {} {}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        status,
        status_text,
        body.len(),
        body
    );
    stream.write_all(response.as_bytes()).await?;
    stream.shutdown().await
}

fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

fn open_browser(url: &str) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    let cmd = std::process::Command::new("open").arg(url).spawn();
    #[cfg(target_os = "linux")]
    let cmd = std::process::Command::new("xdg-open").arg(url).spawn();
    #[cfg(target_os = "windows")]
    let cmd = std::process::Command::new("cmd")
        .args(["/C", "start", "", url])
        .spawn();

    cmd.map(|_| ()).map_err(|e| format!("Failed to open browser: {}", e))
}
