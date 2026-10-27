//! With no connection, a cloud provider can't answer, so Skim hands the request
//! to an on-device model instead: Apple Intelligence where the Mac has it, then
//! a downloaded MLX model, then a downloaded llama.cpp model. Settings are not
//! changed; only the request in hand is rerouted, and the cloud provider is
//! used again as soon as its host answers.

use crate::db::models::AiSettings;
use serde::Serialize;
use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Runtime};

/// How long a reachability answer is trusted. An unreachable host is checked
/// again sooner so the cloud provider comes back quickly after a tunnel.
const REACHABLE_TTL: Duration = Duration::from_secs(20);
const UNREACHABLE_TTL: Duration = Duration::from_secs(5);
const PROBE_TIMEOUT: Duration = Duration::from_millis(2_500);
const LOCAL_AVAILABILITY_TTL: Duration = Duration::from_secs(600);

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct OfflineAiStatus {
    /// The configured provider's host can't be reached.
    pub offline: bool,
    /// The on-device provider requests go to while offline, if one is ready.
    pub fallback_provider: Option<String>,
    pub fallback_label: Option<String>,
}

/// The host (and port) a provider talks to, or None when it runs on this Mac
/// and needs no connection.
pub fn provider_host(settings: &AiSettings) -> Option<(String, u16)> {
    let endpoint_host = || {
        settings
            .endpoint
            .as_deref()
            .map(str::trim)
            .filter(|endpoint| !endpoint.is_empty())
            .and_then(|endpoint| url::Url::parse(endpoint).ok())
            .and_then(|url| Some((url.host_str()?.to_string(), url.port_or_known_default()?)))
    };
    let host = match settings.provider.as_str() {
        "none" | "local" | "mlx" | "foundation-models" | "ds4" | "ollama" => return None,
        "anthropic" | "claude-subscription" | "claude-cli" => ("api.anthropic.com".to_string(), 443),
        "openai" => ("api.openai.com".to_string(), 443),
        "chatgpt-subscription" => ("chatgpt.com".to_string(), 443),
        "xai" => ("api.x.ai".to_string(), 443),
        "openrouter" => endpoint_host().unwrap_or(("openrouter.ai".to_string(), 443)),
        "custom" => endpoint_host()?,
        _ => return None,
    };
    (!is_local_host(&host.0)).then_some(host)
}

fn is_local_host(host: &str) -> bool {
    let host = host.trim_matches(|c| c == '[' || c == ']').to_ascii_lowercase();
    host == "localhost"
        || host.ends_with(".local")
        || host.ends_with(".localhost")
        || host
            .parse::<std::net::IpAddr>()
            .is_ok_and(|ip| match ip {
                std::net::IpAddr::V4(v4) => v4.is_loopback() || v4.is_private() || v4.is_link_local(),
                std::net::IpAddr::V6(v6) => v6.is_loopback(),
            })
}

/// A proxy the system routes HTTPS through stands in for the provider host:
/// reaching it is what matters, and a direct connection may be blocked.
fn proxy_host() -> Option<(String, u16)> {
    ["HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"]
        .iter()
        .find_map(|name| std::env::var(name).ok().filter(|value| !value.trim().is_empty()))
        .and_then(|value| url::Url::parse(value.trim()).ok())
        .and_then(|url| Some((url.host_str()?.to_string(), url.port_or_known_default()?)))
}

fn reachability_cache() -> &'static Mutex<HashMap<String, (Instant, bool)>> {
    static CACHE: OnceLock<Mutex<HashMap<String, (Instant, bool)>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Whether `host` accepts a TCP connection right now. With no network the
/// name lookup fails at once, so this is quick exactly when it matters.
pub async fn host_reachable(host: &str, port: u16) -> bool {
    let (host, port) = proxy_host().unwrap_or((host.to_string(), port));
    let key = format!("{host}:{port}");
    if let Ok(cache) = reachability_cache().lock() {
        if let Some((checked, reachable)) = cache.get(&key) {
            let ttl = if *reachable { REACHABLE_TTL } else { UNREACHABLE_TTL };
            if checked.elapsed() < ttl {
                return *reachable;
            }
        }
    }
    let reachable = probe(&host, port).await;
    if let Ok(mut cache) = reachability_cache().lock() {
        cache.insert(key, (Instant::now(), reachable));
    }
    reachable
}

async fn probe(host: &str, port: u16) -> bool {
    matches!(
        tokio::time::timeout(PROBE_TIMEOUT, tokio::net::TcpStream::connect((host, port))).await,
        Ok(Ok(_))
    )
}

/// Whether the provider in `settings` needs a connection it doesn't have.
pub async fn provider_offline(settings: &AiSettings) -> bool {
    match provider_host(settings) {
        Some((host, port)) => !host_reachable(&host, port).await,
        None => false,
    }
}

pub fn fallback_label(provider: &str) -> &'static str {
    match provider {
        "foundation-models" => "Apple Intelligence",
        "mlx" => "On-device MLX",
        "local" => "Local model",
        _ => "On-device model",
    }
}

/// The on-device provider (and its model) that can answer on this Mac.
#[derive(Clone, Debug, PartialEq)]
struct LocalChoice {
    provider: String,
    model: Option<String>,
    local_model_path: Option<String>,
}

fn local_choice_cache() -> &'static Mutex<Option<(Instant, String, Option<LocalChoice>)>> {
    static CACHE: OnceLock<Mutex<Option<(Instant, String, Option<LocalChoice>)>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(None))
}

fn saved_mlx_repo(settings: &AiSettings) -> String {
    settings
        .provider_credentials
        .get("mlx")
        .and_then(|saved| saved.model.clone())
        .filter(|model| model.contains('/'))
        .unwrap_or_else(|| crate::commands::ai::default_model("mlx"))
}

fn saved_llama_path(settings: &AiSettings) -> Option<String> {
    settings
        .provider_credentials
        .get("local")
        .and_then(|saved| saved.local_model_path.clone())
        .or_else(|| settings.local_model_path.clone())
        .filter(|path| !path.trim().is_empty() && std::path::Path::new(path).is_file())
}

#[cfg(target_os = "macos")]
async fn find_local_choice<R: Runtime>(settings: &AiSettings, app: &AppHandle<R>) -> Option<LocalChoice> {
    use tauri_plugin_skim_ai::{RepoIdArgs, SkimAiExt};
    let mlx_repo = saved_mlx_repo(settings);
    let llama_path = saved_llama_path(settings);
    let app = app.clone();
    tokio::task::spawn_blocking(move || {
        let plugin = app.skim_ai();
        if plugin.fm_is_available().unwrap_or(false) {
            return Some(LocalChoice { provider: "foundation-models".into(), model: Some("foundation-model".into()), local_model_path: None });
        }
        if plugin.mlx_is_model_downloaded(RepoIdArgs { repo_id: mlx_repo.clone() }).unwrap_or(false) {
            return Some(LocalChoice { provider: "mlx".into(), model: Some(mlx_repo), local_model_path: None });
        }
        llama_path.map(|path| LocalChoice { provider: "local".into(), model: None, local_model_path: Some(path) })
    })
    .await
    .ok()
    .flatten()
}

#[cfg(not(target_os = "macos"))]
async fn find_local_choice<R: Runtime>(settings: &AiSettings, _app: &AppHandle<R>) -> Option<LocalChoice> {
    if cfg!(target_os = "ios") {
        return None;
    }
    saved_llama_path(settings).map(|path| LocalChoice { provider: "local".into(), model: None, local_model_path: Some(path) })
}

/// Checking Apple Intelligence goes through the AI helper, which can be busy
/// with a long completion, so the answer is kept for a while.
async fn local_choice<R: Runtime>(settings: &AiSettings, app: &AppHandle<R>) -> Option<LocalChoice> {
    let key = format!("{}|{:?}", saved_mlx_repo(settings), saved_llama_path(settings));
    if let Ok(cache) = local_choice_cache().lock() {
        if let Some((checked, cached_key, choice)) = cache.as_ref() {
            if *cached_key == key && checked.elapsed() < LOCAL_AVAILABILITY_TTL {
                return choice.clone();
            }
        }
    }
    let choice = find_local_choice(settings, app).await;
    if let Ok(mut cache) = local_choice_cache().lock() {
        *cache = Some((Instant::now(), key, choice.clone()));
    }
    choice
}

fn reroute(settings: &mut AiSettings, choice: &LocalChoice) {
    settings.provider = choice.provider.clone();
    settings.model = choice.model.clone();
    settings.local_model_path = choice.local_model_path.clone();
    settings.api_key = None;
    settings.endpoint = None;
    settings.oauth_access_token = None;
}

/// Reroutes `settings` to an on-device provider when its cloud provider can't
/// be reached. Returns the provider used instead, or None when nothing changed
/// (online, already local, or no on-device model is ready).
pub async fn fallback_when_offline<R: Runtime>(settings: &mut AiSettings, app: &AppHandle<R>) -> Option<String> {
    if !provider_offline(settings).await {
        return None;
    }
    let choice = local_choice(settings, app).await?;
    log::info!("No connection to {}; using {} instead", settings.provider, choice.provider);
    reroute(settings, &choice);
    Some(choice.provider)
}

/// What the AI controls show: whether the configured provider is offline and
/// which on-device model answers meanwhile.
#[tauri::command]
pub async fn get_offline_ai_status(
    app: crate::AppHandle,
    db: tauri::State<'_, crate::db::Database>,
) -> Result<OfflineAiStatus, String> {
    let settings: crate::db::models::AppSettings = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        crate::db::queries::get_setting(&conn, "app_settings")
            .map_err(|e| e.to_string())?
            .as_deref()
            .and_then(|json| serde_json::from_str(json).ok())
            .unwrap_or_default()
    };
    let offline = provider_offline(&settings.ai).await;
    let fallback = if offline { local_choice(&settings.ai, &app).await } else { None };
    Ok(OfflineAiStatus {
        offline,
        fallback_label: fallback.as_ref().map(|choice| fallback_label(&choice.provider).to_string()),
        fallback_provider: fallback.map(|choice| choice.provider),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn settings(provider: &str, endpoint: Option<&str>) -> AiSettings {
        let mut settings = crate::db::models::AppSettings::default().ai;
        settings.provider = provider.into();
        settings.endpoint = endpoint.map(str::to_string);
        settings
    }

    #[test]
    fn cloud_providers_have_a_host_and_local_ones_do_not() {
        assert_eq!(provider_host(&settings("claude-subscription", None)), Some(("api.anthropic.com".into(), 443)));
        assert_eq!(provider_host(&settings("xai", None)), Some(("api.x.ai".into(), 443)));
        for local in ["none", "local", "mlx", "foundation-models", "ds4", "ollama"] {
            assert_eq!(provider_host(&settings(local, None)), None, "{local}");
        }
    }

    #[test]
    fn custom_endpoints_on_this_machine_or_lan_need_no_connection() {
        assert_eq!(provider_host(&settings("custom", Some("http://localhost:1234/v1"))), None);
        assert_eq!(provider_host(&settings("custom", Some("http://192.168.1.20:8080"))), None);
        assert_eq!(provider_host(&settings("custom", Some("http://studio.local:8080"))), None);
        assert_eq!(
            provider_host(&settings("custom", Some("https://llm.example.com/v1"))),
            Some(("llm.example.com".into(), 443))
        );
        assert_eq!(
            provider_host(&settings("openrouter", Some("https://proxy.example.com:8443/api"))),
            Some(("proxy.example.com".into(), 8443))
        );
    }

    #[test]
    fn reroute_swaps_in_the_local_model_and_drops_cloud_credentials() {
        let mut ai = settings("anthropic", Some("https://api.anthropic.com"));
        ai.api_key = Some("sk-ant".into());
        ai.model = Some("claude-sonnet-5-5".into());
        ai.oauth_access_token = Some("token".into());
        reroute(&mut ai, &LocalChoice { provider: "mlx".into(), model: Some("mlx-community/Qwen3.5-4B-4bit".into()), local_model_path: None });
        assert_eq!(ai.provider, "mlx");
        assert_eq!(ai.model.as_deref(), Some("mlx-community/Qwen3.5-4B-4bit"));
        assert!(ai.api_key.is_none() && ai.endpoint.is_none() && ai.oauth_access_token.is_none());
    }

    #[tokio::test]
    async fn an_unresolvable_host_is_unreachable_quickly() {
        let started = Instant::now();
        assert!(!probe("skim-offline-probe.invalid", 443).await);
        assert!(started.elapsed() < PROBE_TIMEOUT + Duration::from_millis(500));
    }
}
