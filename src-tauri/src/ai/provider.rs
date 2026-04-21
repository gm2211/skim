use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use super::local_provider::SharedModelState;
use crate::db::models::AiSettings;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatMessage {
    pub role: String,
    pub content: String,
    /// Optional Anthropic-style content blocks. When present, providers that
    /// support tool-use (Anthropic API, Claude subscription) send these
    /// verbatim instead of the plain `content` string. This lets the chat
    /// orchestrator thread `tool_result` blocks back through a multi-turn
    /// tool-use loop. Other providers ignore this field.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content_blocks: Option<Vec<serde_json::Value>>,
}

impl ChatMessage {
    pub fn text(role: impl Into<String>, content: impl Into<String>) -> Self {
        Self {
            role: role.into(),
            content: content.into(),
            content_blocks: None,
        }
    }
}

/// Anthropic-style tool definition. Passed through to providers that support
/// tool-use. Schema matches the Anthropic `tools` API field shape.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolDef {
    pub name: String,
    pub description: String,
    pub input_schema: serde_json::Value,
}

/// A single `tool_use` block returned by the model. `input` is the raw JSON
/// argument object the model produced for this call.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolUse {
    pub id: String,
    pub name: String,
    pub input: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatRequest {
    pub model: String,
    pub messages: Vec<ChatMessage>,
    pub temperature: Option<f64>,
    pub max_tokens: Option<i64>,
    #[serde(default)]
    pub json_mode: bool,
    /// Tools the model may invoke. Only sent by providers that implement
    /// tool-use (Anthropic API, Claude subscription). Other providers log and
    /// drop this field so callers can reliably fall back to text-only.
    #[serde(default)]
    pub tools: Option<Vec<ToolDef>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatResponse {
    pub content: String,
    pub model: String,
    pub usage: Option<TokenUsage>,
    /// Tool invocations emitted by the model in this turn. Always empty for
    /// providers that don't support tool-use.
    #[serde(default)]
    pub tool_uses: Vec<ToolUse>,
    /// Stop reason from the provider, when available. Used by the
    /// orchestrator to detect `tool_use` termination on Anthropic.
    #[serde(default)]
    pub stop_reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TokenUsage {
    pub prompt_tokens: Option<i64>,
    pub completion_tokens: Option<i64>,
}

#[async_trait]
pub trait AiProvider: Send + Sync {
    async fn chat(&self, request: ChatRequest) -> Result<ChatResponse, String>;
    fn name(&self) -> &str;
}

/// OpenAI-compatible provider that works with:
/// - OpenAI directly
/// - LiteLLM proxy
/// - OpenRouter
/// - Ollama (OpenAI-compatible endpoint)
/// - LM Studio
/// - llama.cpp server
/// - Any OpenAI-compatible API
pub struct OpenAiCompatibleProvider {
    client: reqwest::Client,
    base_url: String,
    api_key: Option<String>,
    provider_name: String,
}

impl OpenAiCompatibleProvider {
    pub fn new(base_url: &str, api_key: Option<&str>, provider_name: &str) -> Self {
        Self {
            client: reqwest::Client::new(),
            base_url: base_url.trim_end_matches('/').to_string(),
            api_key: api_key.map(|s| s.to_string()),
            provider_name: provider_name.to_string(),
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

#[async_trait]
impl AiProvider for OpenAiCompatibleProvider {
    async fn chat(&self, request: ChatRequest) -> Result<ChatResponse, String> {
        let url = format!("{}/v1/chat/completions", self.base_url);

        if request.tools.as_ref().map(|t| !t.is_empty()).unwrap_or(false) {
            log::info!(
                "OpenAiCompatibleProvider ({}): dropping {} tool(s) — tool-use loop is Anthropic-only in this codebase",
                self.provider_name,
                request.tools.as_ref().map(|t| t.len()).unwrap_or(0),
            );
        }

        // Strip Anthropic-style content_blocks — OpenAI's chat completions
        // schema doesn't accept them. Fall back to the plain `content` string.
        let messages: Vec<serde_json::Value> = request
            .messages
            .iter()
            .map(|m| serde_json::json!({"role": m.role, "content": m.content}))
            .collect();

        let mut body = serde_json::json!({
            "model": request.model,
            "messages": messages,
            "temperature": request.temperature.unwrap_or(0.3),
            "max_tokens": request.max_tokens.unwrap_or(2048),
        });
        if request.json_mode {
            body["response_format"] = serde_json::json!({"type": "json_object"});
        }

        let mut req = self.client.post(&url).json(&body);

        if let Some(ref key) = self.api_key {
            req = req.bearer_auth(key);
        }

        let response = req
            .send()
            .await
            .map_err(|e| format!("AI request failed: {}", e))?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            return Err(format!("AI API error ({}): {}", status, body));
        }

        let ai_response: OpenAiResponse = response
            .json()
            .await
            .map_err(|e| format!("Failed to parse AI response: {}", e))?;

        let content = ai_response
            .choices
            .first()
            .and_then(|c| c.message.content.clone())
            .unwrap_or_default();

        Ok(ChatResponse {
            content,
            model: ai_response.model.unwrap_or(request.model),
            usage: ai_response.usage.map(|u| TokenUsage {
                prompt_tokens: u.prompt_tokens,
                completion_tokens: u.completion_tokens,
            }),
            tool_uses: Vec::new(),
            stop_reason: None,
        })
    }

    fn name(&self) -> &str {
        &self.provider_name
    }
}

pub struct AnthropicProvider {
    client: reqwest::Client,
    api_key: String,
}

impl AnthropicProvider {
    pub fn new(api_key: &str) -> Self {
        let key = api_key.trim().to_string();
        log::debug!("AnthropicProvider: key length={}, prefix={}", key.len(), &key[..key.len().min(10)]);
        Self {
            client: reqwest::Client::new(),
            api_key: key,
        }
    }
}

#[derive(Deserialize)]
struct AnthropicResponse {
    content: Vec<AnthropicContent>,
    model: Option<String>,
    usage: Option<AnthropicUsage>,
    #[serde(default)]
    stop_reason: Option<String>,
}

/// A single content block in an Anthropic response. We care about `text` and
/// `tool_use`; other block types (e.g. `thinking`) are deserialized with their
/// type but their payload is ignored.
#[derive(Deserialize)]
struct AnthropicContent {
    #[serde(rename = "type")]
    block_type: Option<String>,
    text: Option<String>,
    // tool_use fields
    id: Option<String>,
    name: Option<String>,
    input: Option<serde_json::Value>,
}

#[derive(Deserialize)]
struct AnthropicUsage {
    input_tokens: Option<i64>,
    output_tokens: Option<i64>,
}

/// Translate internal `ChatMessage`s into the Anthropic messages-API shape.
/// Non-system messages with `content_blocks` pass their blocks through
/// verbatim (used for `tool_result` replies). Plain-text messages become a
/// single text block.
fn anthropic_messages(messages: &[ChatMessage]) -> Vec<serde_json::Value> {
    messages
        .iter()
        .filter(|m| m.role != "system")
        .map(|m| {
            if let Some(blocks) = &m.content_blocks {
                serde_json::json!({"role": m.role, "content": blocks})
            } else {
                serde_json::json!({"role": m.role, "content": m.content})
            }
        })
        .collect()
}

/// Parse an Anthropic response into our `(text, tool_uses)` pair. Concatenates
/// all `text` blocks (rare to have >1 but allowed) and collects `tool_use`
/// blocks in emission order so the orchestrator can execute them sequentially.
fn parse_anthropic_content(content: &[AnthropicContent]) -> (String, Vec<ToolUse>) {
    let mut text = String::new();
    let mut tool_uses = Vec::new();
    for block in content {
        match block.block_type.as_deref() {
            Some("tool_use") => {
                if let (Some(id), Some(name)) = (block.id.clone(), block.name.clone()) {
                    tool_uses.push(ToolUse {
                        id,
                        name,
                        input: block.input.clone().unwrap_or(serde_json::Value::Null),
                    });
                }
            }
            _ => {
                if let Some(t) = &block.text {
                    text.push_str(t);
                }
            }
        }
    }
    (text, tool_uses)
}

#[async_trait]
impl AiProvider for AnthropicProvider {
    async fn chat(&self, request: ChatRequest) -> Result<ChatResponse, String> {
        let system_msg = request.messages.iter()
            .find(|m| m.role == "system")
            .map(|m| m.content.clone());

        let messages = anthropic_messages(&request.messages);

        let mut body = serde_json::json!({
            "model": request.model,
            "messages": messages,
            "max_tokens": request.max_tokens.unwrap_or(2048),
        });

        if let Some(temp) = request.temperature {
            body["temperature"] = serde_json::json!(temp);
        }
        if let Some(sys) = &system_msg {
            body["system"] = serde_json::json!(sys);
        }
        if let Some(tools) = &request.tools {
            if !tools.is_empty() {
                body["tools"] = serde_json::json!(tools);
            }
        }

        let response = self.client
            .post("https://api.anthropic.com/v1/messages")
            .header("x-api-key", &self.api_key)
            .header("anthropic-version", "2023-06-01")
            .header("content-type", "application/json")
            .json(&body)
            .send()
            .await
            .map_err(|e| format!("Anthropic request failed: {}", e))?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            log::error!("Anthropic API error: status={}, key_len={}, key_prefix={}", status, self.api_key.len(), &self.api_key[..self.api_key.len().min(10)]);
            return Err(format!("Anthropic API error ({}): {}", status, body));
        }

        let api_response: AnthropicResponse = response
            .json()
            .await
            .map_err(|e| format!("Failed to parse Anthropic response: {}", e))?;

        let (content, tool_uses) = parse_anthropic_content(&api_response.content);

        Ok(ChatResponse {
            content,
            model: api_response.model.unwrap_or(request.model),
            usage: api_response.usage.map(|u| TokenUsage {
                prompt_tokens: u.input_tokens,
                completion_tokens: u.output_tokens,
            }),
            tool_uses,
            stop_reason: api_response.stop_reason,
        })
    }

    fn name(&self) -> &str {
        "anthropic"
    }
}

/// Provider that uses a Claude Pro/Max OAuth Bearer token directly (no CLI
/// subprocess). Token is resolved at the call site and injected here.
///
/// Refresh logic lives in `commands::claude_oauth` — a background task or
/// dedicated command refreshes and persists before expiry; this provider just
/// reads whatever is current and surfaces 401 on stale tokens so the UI can
/// prompt re-auth.
pub struct ClaudeSubscriptionProvider {
    client: reqwest::Client,
    access_token: String,
}

impl ClaudeSubscriptionProvider {
    pub fn new(access_token: String) -> Self {
        Self { client: reqwest::Client::new(), access_token }
    }
}

#[async_trait]
impl AiProvider for ClaudeSubscriptionProvider {
    async fn chat(&self, request: ChatRequest) -> Result<ChatResponse, String> {
        use super::claude_oauth::{BETA_HEADER, SYSTEM_PREFIX};
        let token = self.access_token.clone();

        let user_system = request.messages.iter()
            .find(|m| m.role == "system")
            .map(|m| m.content.clone());
        let messages = anthropic_messages(&request.messages);

        let mut system_blocks = vec![serde_json::json!({"type": "text", "text": SYSTEM_PREFIX})];
        if let Some(sys) = user_system {
            system_blocks.push(serde_json::json!({"type": "text", "text": sys}));
        }

        let mut body = serde_json::json!({
            "model": request.model,
            "messages": messages,
            "max_tokens": request.max_tokens.unwrap_or(2048),
            "system": system_blocks,
        });
        if let Some(temp) = request.temperature {
            body["temperature"] = serde_json::json!(temp);
        }
        if let Some(tools) = &request.tools {
            if !tools.is_empty() {
                body["tools"] = serde_json::json!(tools);
            }
        }

        let resp = self.client
            .post("https://api.anthropic.com/v1/messages")
            .header("Authorization", format!("Bearer {}", token))
            .header("anthropic-version", "2023-06-01")
            .header("anthropic-beta", BETA_HEADER)
            .header("content-type", "application/json")
            .json(&body)
            .send()
            .await
            .map_err(|e| format!("Claude subscription request failed: {}", e))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(format!("Claude subscription API {}: {}", status, body));
        }

        let api_response: AnthropicResponse = resp.json().await
            .map_err(|e| format!("Parse Claude subscription response: {}", e))?;
        let (content, tool_uses) = parse_anthropic_content(&api_response.content);
        Ok(ChatResponse {
            content,
            model: api_response.model.unwrap_or(request.model),
            usage: api_response.usage.map(|u| TokenUsage {
                prompt_tokens: u.input_tokens,
                completion_tokens: u.output_tokens,
            }),
            tool_uses,
            stop_reason: api_response.stop_reason,
        })
    }

    fn name(&self) -> &str { "claude-subscription" }
}

/// Provider that uses the Claude Code CLI to make API calls.
/// This lets users with Claude Pro/Max subscriptions use their subscription
/// for summarization without needing an API key.
pub struct ClaudeCliProvider {
    api_key: Option<String>,
}

impl ClaudeCliProvider {
    pub fn new(api_key: Option<&str>) -> Result<Self, String> {
        // Verify claude CLI is available
        let check = std::process::Command::new("which")
            .arg("claude")
            .output()
            .map_err(|e| format!("Failed to check for claude CLI: {}", e))?;
        if !check.status.success() {
            return Err("Claude Code CLI not found. Install it from https://claude.ai/code".to_string());
        }
        Ok(Self {
            api_key: api_key
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                // OAuth tokens don't work as ANTHROPIC_API_KEY — ignore them
                .filter(|s| !s.starts_with("sk-ant-oat")),
        })
    }
}

#[derive(Deserialize)]
struct ClaudeCliResponse {
    result: Option<String>,
    subtype: Option<String>,
    is_error: Option<bool>,
    #[serde(rename = "type")]
    resp_type: Option<String>,
    error: Option<serde_json::Value>,
    message: Option<serde_json::Value>,
    api_error_status: Option<serde_json::Value>,
    stop_reason: Option<String>,
    usage: Option<ClaudeCliUsage>,
}

#[derive(Deserialize)]
struct ClaudeCliUsage {
    input_tokens: Option<i64>,
    output_tokens: Option<i64>,
}

#[async_trait]
impl AiProvider for ClaudeCliProvider {
    async fn chat(&self, request: ChatRequest) -> Result<ChatResponse, String> {
        if request.tools.as_ref().map(|t| !t.is_empty()).unwrap_or(false) {
            log::info!(
                "ClaudeCliProvider: dropping {} tool(s) — CLI wrapper doesn't expose tool-use",
                request.tools.as_ref().map(|t| t.len()).unwrap_or(0),
            );
        }

        let system_msg = request.messages.iter()
            .find(|m| m.role == "system")
            .map(|m| m.content.clone());

        // Build the user prompt from non-system messages
        let user_prompt = request.messages.iter()
            .filter(|m| m.role != "system")
            .map(|m| m.content.as_str())
            .collect::<Vec<_>>()
            .join("\n\n");

        // Map common model names to claude-cli compatible names
        let model = match request.model.as_str() {
            m if m.starts_with("claude-") || m == "sonnet" || m == "opus" || m == "haiku" => request.model.clone(),
            // If a non-Claude model is configured, default to sonnet
            other => {
                log::warn!("claude-cli provider: model '{}' is not a Claude model, defaulting to sonnet", other);
                "sonnet".to_string()
            }
        };
        let api_key = self.api_key.clone();

        // Run claude CLI in a blocking task since it spawns a process
        let result = tokio::task::spawn_blocking(move || {
            use std::io::Write;

            let mut cmd = std::process::Command::new("claude");
            // Pass the prompt via stdin to avoid hitting argv length limits
            // with large article contexts.
            cmd.args([
                "-p",
                "--output-format", "json",
                "--model", &model,
                "--max-turns", "1",
            ]);

            if let Some(ref key) = api_key {
                cmd.env("ANTHROPIC_API_KEY", key);
            }

            if let Some(ref sys) = system_msg {
                cmd.args(["--append-system-prompt", sys]);
            }

            // Set working directory to /tmp to avoid scanning user directories
            // which triggers macOS TCC prompts (Photos, Desktop, Dropbox).
            cmd.current_dir("/tmp");

            log::info!(
                "ClaudeCliProvider: running claude CLI with model={}, prompt {} bytes",
                &model,
                user_prompt.len()
            );

            cmd.stdin(std::process::Stdio::piped());
            cmd.stdout(std::process::Stdio::piped());
            cmd.stderr(std::process::Stdio::piped());

            let mut child = cmd
                .spawn()
                .map_err(|e| format!("Failed to run claude CLI: {}", e))?;

            if let Some(mut stdin) = child.stdin.take() {
                stdin
                    .write_all(user_prompt.as_bytes())
                    .map_err(|e| format!("Failed to write prompt to claude stdin: {}", e))?;
                // Explicitly drop to close stdin so claude knows input is done.
                drop(stdin);
            }

            let output = child
                .wait_with_output()
                .map_err(|e| format!("Failed to read claude CLI output: {}", e))?;

            let stdout = String::from_utf8_lossy(&output.stdout).to_string();
            let stderr = String::from_utf8_lossy(&output.stderr).to_string();

            if !stderr.is_empty() {
                log::debug!("claude CLI stderr: {}", stderr);
            }

            if stdout.trim().is_empty() {
                return Err(format!(
                    "claude CLI returned no output. Exit code: {}. stderr: {}",
                    output.status, stderr
                ));
            }

            let cli_resp: ClaudeCliResponse = serde_json::from_str(&stdout)
                .map_err(|e| format!("Failed to parse claude CLI output: {}. Output: {}", e, &stdout[..stdout.len().min(500)]))?;

            if cli_resp.is_error.unwrap_or(false) {
                // Surface whatever detail the CLI gave us. Prior code only
                // reported `result`, which is empty on auth/transport errors.
                let detail = cli_resp
                    .result
                    .clone()
                    .filter(|s| !s.trim().is_empty())
                    .or_else(|| cli_resp.api_error_status.as_ref().map(|v| format!("api_error_status={}", v)))
                    .or_else(|| cli_resp.error.as_ref().map(|v| v.to_string()))
                    .or_else(|| cli_resp.message.as_ref().map(|v| v.to_string()))
                    .unwrap_or_else(|| {
                        format!(
                            "no result/error field. subtype={:?} type={:?} stop_reason={:?} raw={}",
                            cli_resp.subtype,
                            cli_resp.resp_type,
                            cli_resp.stop_reason,
                            &stdout[..stdout.len().min(800)]
                        )
                    });
                return Err(format!("claude CLI error: {}", detail));
            }

            if cli_resp.subtype.as_deref() != Some("success") {
                return Err(format!(
                    "claude CLI non-success: subtype={:?}, type={:?}, result={:?}, raw={}",
                    cli_resp.subtype,
                    cli_resp.resp_type,
                    cli_resp.result,
                    &stdout[..stdout.len().min(500)]
                ));
            }

            let content = cli_resp.result.unwrap_or_default();
            let usage = cli_resp.usage.map(|u| TokenUsage {
                prompt_tokens: u.input_tokens,
                completion_tokens: u.output_tokens,
            });

            Ok((content, usage))
        })
        .await
        .map_err(|e| format!("claude CLI task panicked: {}", e))??;

        Ok(ChatResponse {
            content: result.0,
            model: request.model,
            usage: result.1,
            tool_uses: Vec::new(),
            stop_reason: None,
        })
    }

    fn name(&self) -> &str {
        "claude-cli"
    }
}

pub fn create_provider(
    settings: &AiSettings,
    model_state: Option<SharedModelState>,
) -> Result<Box<dyn AiProvider>, String> {
    let api_key = settings.api_key.as_deref();
    let endpoint = settings.endpoint.as_deref();

    match settings.provider.as_str() {
        #[cfg(not(target_os = "ios"))]
        "local" => {
            let model_path = settings
                .local_model_path
                .as_deref()
                .ok_or("No local model selected. Go to Settings to download one.")?;
            let power_mode = settings.local_power_mode.as_deref().unwrap_or("balanced");
            let user_layers = settings.local_gpu_layers;
            let (effective_layers, n_threads) =
                super::local_provider::resolve_power_profile(power_mode, user_layers);
            let state = model_state
                .ok_or("Local model state not available")?;
            Ok(Box::new(super::local_provider::LocalLlmProvider::new(
                model_path,
                effective_layers,
                n_threads,
                state,
            )))
        }
        #[cfg(target_os = "ios")]
        "local" => Err("Local llama.cpp provider is not supported on iOS — use the on-device MLX tier instead".to_string()),
        "openai" => Ok(Box::new(OpenAiCompatibleProvider::new(
            "https://api.openai.com",
            api_key,
            "openai",
        ))),
        "openrouter" => Ok(Box::new(OpenAiCompatibleProvider::new(
            endpoint.unwrap_or("https://openrouter.ai/api"),
            api_key,
            "openrouter",
        ))),
        "ollama" => Ok(Box::new(OpenAiCompatibleProvider::new(
            endpoint.unwrap_or("http://localhost:11434"),
            None,
            "ollama",
        ))),
        "anthropic" => {
            let key = api_key.ok_or("Anthropic requires an API key")?;
            Ok(Box::new(AnthropicProvider::new(key)))
        }
        "claude-cli" => {
            Ok(Box::new(ClaudeCliProvider::new(api_key)?))
        }
        "claude-subscription" => {
            let token = settings.oauth_access_token.clone()
                .ok_or("Not signed in to Claude. Sign in from Settings.")?;
            if token.is_empty() {
                return Err("Not signed in to Claude. Sign in from Settings.".to_string());
            }
            Ok(Box::new(ClaudeSubscriptionProvider::new(token)))
        }
        "custom" => {
            let ep = endpoint.ok_or("Custom provider requires an endpoint URL")?;
            Ok(Box::new(OpenAiCompatibleProvider::new(ep, api_key, "custom")))
        }
        _ => Err(format!("Unknown AI provider: {}", settings.provider)),
    }
}
