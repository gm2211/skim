//! DeepSeek-V4 local provider backed by the bundled `ds4-server` binary.
//!
//! The server is deliberately managed here instead of through the generic
//! llama.cpp model manager: DS4 needs its own Metal runtime and model format.

use super::provider::{AiProvider, ChatRequest, ChatResponse, TokenUsage};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};
use std::time::Duration;
use tokio::sync::Mutex;

const DEFAULT_MODEL: &str = "deepseek-v4-flash";
const STARTUP_TIMEOUT: Duration = Duration::from_secs(240);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(120);

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Ds4Status {
    pub runtime_available: bool,
    pub running: bool,
    pub model_path: Option<String>,
    pub error: Option<String>,
}

struct RuntimeState {
    child: Option<std::process::Child>,
    model_path: Option<PathBuf>,
    port: Option<u16>,
    ready: bool,
    error: Option<String>,
}

pub struct Ds4Runtime {
    state: Mutex<RuntimeState>,
    lifecycle: Mutex<()>,
    inference: Mutex<()>,
    server_path: PathBuf,
    resources_dir: PathBuf,
    client: reqwest::Client,
}

impl Ds4Runtime {
    pub fn new() -> Arc<Self> {
        let server_path = resolve_server_path();
        let resources_dir = resources_dir_for(&server_path);
        Self::with_paths(server_path, resources_dir)
    }

    fn with_paths(server_path: PathBuf, resources_dir: PathBuf) -> Arc<Self> {
        Arc::new(Self {
            state: Mutex::new(RuntimeState {
                child: None,
                model_path: None,
                port: None,
                ready: false,
                error: None,
            }),
            lifecycle: Mutex::new(()),
            inference: Mutex::new(()),
            server_path,
            resources_dir,
            client: reqwest::Client::builder()
                .connect_timeout(Duration::from_secs(3))
                .timeout(REQUEST_TIMEOUT)
                .build()
                .expect("valid DS4 HTTP client configuration"),
        })
    }

    #[cfg(test)]
    pub fn status_sync(&self) -> Ds4Status {
        // Used only by tests and non-async callers. Runtime commands use status.
        let runtime_available = cfg!(target_os = "macos") && self.server_path.is_file();
        Ds4Status {
            runtime_available,
            running: false,
            model_path: None,
            error: None,
        }
    }

    pub async fn status(&self) -> Ds4Status {
        let mut guard = self.state.lock().await;
        reap_dead_child(&mut guard);
        let runtime_available = cfg!(target_os = "macos") && self.server_path.is_file();
        Ds4Status {
            runtime_available,
            running: guard.child.is_some() && guard.ready,
            model_path: guard.model_path.as_ref().map(|p| p.display().to_string()),
            error: guard.error.clone(),
        }
    }

    pub async fn stop(&self) -> Ds4Status {
        let _lifecycle_guard = self.lifecycle.lock().await;
        let mut guard = self.state.lock().await;
        stop_locked(&mut guard);
        let runtime_available = cfg!(target_os = "macos") && self.server_path.is_file();
        Ds4Status {
            runtime_available,
            running: false,
            model_path: None,
            error: guard.error.clone(),
        }
    }

    pub async fn start(&self, model_path: &Path) -> Result<(), String> {
        self.ensure_started(model_path).await.map(|_| ())
    }

    async fn ensure_started(&self, model_path: &Path) -> Result<u16, String> {
        let _lifecycle_guard = self.lifecycle.lock().await;
        validate_model_path(model_path)?;
        if !cfg!(target_os = "macos") {
            return Err("[configure-ai] DS4 is only available on macOS.".to_string());
        }
        if !self.server_path.is_file() {
            return Err(format!(
                "[configure-ai] DS4 runtime not found at {}. Install the bundled Metal runtime.",
                self.server_path.display()
            ));
        }

        let mut guard = self.state.lock().await;
        reap_dead_child(&mut guard);
        if guard.child.is_some() && guard.model_path.as_deref() == Some(model_path) {
            return guard
                .port
                .ok_or_else(|| "DS4 runtime has no listening port".to_string());
        }
        if guard.child.is_some() {
            stop_locked(&mut guard);
        }

        let listener = std::net::TcpListener::bind(("127.0.0.1", 0))
            .map_err(|e| format!("DS4 could not reserve a loopback port: {e}"))?;
        let port = listener
            .local_addr()
            .map_err(|e| format!("DS4 could not read loopback port: {e}"))?
            .port();
        drop(listener);

        let mut command = std::process::Command::new(&self.server_path);
        command
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .current_dir(&self.resources_dir)
            .arg("-m")
            .arg(model_path)
            .arg("--host")
            .arg("127.0.0.1")
            .arg("--port")
            .arg(port.to_string())
            .arg("--ctx")
            .arg("32768")
            .arg("--power")
            .arg("100");
        let child = command
            .spawn()
            .map_err(|e| format!("[configure-ai] Failed to start DS4 runtime: {e}"))?;
        guard.child = Some(child);
        guard.model_path = Some(model_path.to_path_buf());
        guard.port = Some(port);
        guard.ready = false;
        guard.error = None;

        if let Err(error) = self.wait_ready(port, &mut guard).await {
            guard.error = Some(error.clone());
            stop_locked(&mut guard);
            return Err(error);
        }
        guard.ready = true;
        Ok(port)
    }

    async fn wait_ready(&self, port: u16, state: &mut RuntimeState) -> Result<(), String> {
        let url = format!("http://127.0.0.1:{port}/v1/models");
        let deadline = tokio::time::Instant::now() + STARTUP_TIMEOUT;
        loop {
            if tokio::time::Instant::now() >= deadline {
                return Err(
                    "DS4 runtime did not become ready before the startup timeout".to_string(),
                );
            }
            if state
                .child
                .as_mut()
                .and_then(|child| child.try_wait().ok())
                .flatten()
                .is_some()
            {
                return Err("DS4 runtime exited before becoming ready".to_string());
            }
            match self.client.get(&url).send().await {
                Ok(response) if response.status().is_success() => return Ok(()),
                Ok(_) | Err(_) => tokio::time::sleep(Duration::from_millis(150)).await,
            }
        }
    }

    async fn chat(
        &self,
        settings_model_path: &Path,
        request: &ChatRequest,
    ) -> Result<ChatResponse, String> {
        let _inference_guard = self.inference.lock().await;
        let port = self.ensure_started(settings_model_path).await?;
        let url = format!("http://127.0.0.1:{port}/v1/chat/completions");
        let messages: Vec<serde_json::Value> = request
            .messages
            .iter()
            .map(|message| serde_json::json!({"role": message.role, "content": message.content}))
            .collect();
        let mut body = serde_json::json!({
            "model": if request.model.trim().is_empty() { DEFAULT_MODEL } else { request.model.as_str() },
            "messages": messages,
            "temperature": request.temperature.unwrap_or(0.2),
            "max_tokens": request.max_tokens.unwrap_or(512).min(32768),
            "think": false,
        });
        if request.json_mode {
            body["response_format"] = serde_json::json!({"type": "json_object"});
        }
        let response = self
            .client
            .post(url)
            .json(&body)
            .send()
            .await
            .map_err(|e| format!("DS4 request failed: {e}"))?;
        if !response.status().is_success() {
            let status = response.status();
            let text = response.text().await.unwrap_or_default();
            return Err(format!("DS4 API error ({status}): {text}"));
        }
        let payload: OpenAiResponse = response
            .json()
            .await
            .map_err(|e| format!("Failed to parse DS4 response: {e}"))?;
        let choice = payload
            .choices
            .first()
            .ok_or_else(|| "DS4 returned no choices".to_string())?;
        Ok(ChatResponse {
            content: choice.message.content.clone().unwrap_or_default(),
            model: payload.model.unwrap_or_else(|| request.model.clone()),
            usage: payload.usage.map(|usage| TokenUsage {
                prompt_tokens: usage.prompt_tokens,
                completion_tokens: usage.completion_tokens,
            }),
            tool_uses: Vec::new(),
            stop_reason: None,
        })
    }
}

impl Drop for Ds4Runtime {
    fn drop(&mut self) {
        if let Ok(mut guard) = self.state.try_lock() {
            stop_locked(&mut guard);
        }
    }
}

#[derive(Deserialize)]
struct OpenAiResponse {
    choices: Vec<OpenAiChoice>,
    model: Option<String>,
    usage: Option<OpenAiUsage>,
}
#[derive(Deserialize)]
struct OpenAiChoice {
    message: OpenAiMessage,
}
#[derive(Deserialize)]
struct OpenAiMessage {
    content: Option<String>,
}
#[derive(Deserialize)]
struct OpenAiUsage {
    prompt_tokens: Option<i64>,
    completion_tokens: Option<i64>,
}

pub struct Ds4Provider {
    runtime: Arc<Ds4Runtime>,
    model_path: PathBuf,
}

impl Ds4Provider {
    pub fn new(runtime: Arc<Ds4Runtime>, model_path: impl Into<PathBuf>) -> Self {
        Self {
            runtime,
            model_path: model_path.into(),
        }
    }
}

#[async_trait]
impl AiProvider for Ds4Provider {
    async fn chat(&self, request: ChatRequest) -> Result<ChatResponse, String> {
        self.runtime.chat(&self.model_path, &request).await
    }
    fn name(&self) -> &str {
        "ds4"
    }
}

fn reap_dead_child(state: &mut RuntimeState) {
    if state
        .child
        .as_mut()
        .and_then(|child| child.try_wait().ok())
        .flatten()
        .is_some()
    {
        state.child = None;
        state.model_path = None;
        state.port = None;
    }
}

fn stop_locked(state: &mut RuntimeState) {
    if let Some(mut child) = state.child.take() {
        let _ = child.kill();
        let _ = child.wait();
    }
    state.model_path = None;
    state.port = None;
    state.ready = false;
}

pub fn validate_model_path(path: &Path) -> Result<(), String> {
    if !path.is_file() {
        return Err(format!(
            "[configure-ai] DS4 model file not found: {}",
            path.display()
        ));
    }
    if path
        .extension()
        .and_then(|ext| ext.to_str())
        .map(|ext| ext.eq_ignore_ascii_case("gguf"))
        != Some(true)
    {
        return Err("[configure-ai] DS4 requires a .gguf model file.".to_string());
    }
    Ok(())
}

fn resources_dir_for(server_path: &Path) -> PathBuf {
    let parent = server_path.parent().unwrap_or_else(|| Path::new("."));
    if parent.file_name().and_then(|name| name.to_str()) == Some("MacOS") {
        return parent
            .parent()
            .map(|contents| contents.join("Resources/ds4"))
            .unwrap_or_else(|| PathBuf::from("Resources/ds4"));
    }
    parent.to_path_buf()
}

fn resolve_server_path() -> PathBuf {
    let current = std::env::current_exe().ok();
    let sibling = current
        .as_ref()
        .and_then(|path| path.parent().map(|parent| parent.join("ds4-server")));
    if sibling.as_ref().is_some_and(|path| path.is_file()) {
        return sibling.expect("checked DS4 sibling path");
    }
    let debug = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .map(|root| root.join(".build/ds4-source/ds4-server"));
    if debug.as_ref().is_some_and(|path| path.is_file()) {
        return debug.expect("checked DS4 debug path");
    }
    sibling.unwrap_or_else(|| PathBuf::from("ds4-server"))
}

static RUNTIME: OnceLock<Arc<Ds4Runtime>> = OnceLock::new();
pub fn runtime() -> Arc<Ds4Runtime> {
    RUNTIME.get_or_init(Ds4Runtime::new).clone()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_missing_or_non_gguf_models() {
        assert!(validate_model_path(Path::new("/definitely/missing.gguf")).is_err());
        let path = std::env::temp_dir().join(format!("skim-ds4-test-{}.bin", std::process::id()));
        std::fs::write(&path, b"test").unwrap();
        assert!(validate_model_path(&path).is_err());
        let _ = std::fs::remove_file(path);
    }
    #[test]
    fn status_is_stopped_when_runtime_not_started() {
        let runtime = Ds4Runtime::new();
        let status = runtime.status_sync();
        assert!(!status.running);
        assert!(status.model_path.is_none());
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn exited_server_is_reported_without_waiting_for_timeout() {
        let model = std::env::temp_dir().join(format!("skim-ds4-exit-test-{}.gguf", std::process::id()));
        std::fs::write(&model, b"test").unwrap();
        let runtime = Ds4Runtime::with_paths(PathBuf::from("/usr/bin/false"), std::env::temp_dir());
        let started = std::time::Instant::now();
        let error = runtime.start(&model).await.unwrap_err();
        assert!(error.contains("exited before becoming ready"));
        assert!(started.elapsed() < Duration::from_secs(5));
        let _ = std::fs::remove_file(model);
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn missing_server_returns_actionable_startup_error() {
        let model = std::env::temp_dir().join(format!("skim-ds4-test-{}.gguf", std::process::id()));
        std::fs::write(&model, b"test").unwrap();
        let runtime = Ds4Runtime::with_paths(
            PathBuf::from("/definitely/missing/ds4-server"),
            std::env::temp_dir(),
        );
        let error = runtime.start(&model).await.unwrap_err();
        assert!(error.contains("DS4 runtime not found"));
        let _ = std::fs::remove_file(model);
    }
}
