use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use super::local_provider::SharedModelState;
use crate::db::models::AiSettings;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatMessage {
    pub role: String,
    pub content: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatRequest {
    pub model: String,
    pub messages: Vec<ChatMessage>,
    pub temperature: Option<f64>,
    pub max_tokens: Option<i64>,
    #[serde(default)]
    pub json_mode: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatResponse {
    pub content: String,
    pub model: String,
    pub usage: Option<TokenUsage>,
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

        let mut body = serde_json::json!({
            "model": request.model,
            "messages": request.messages,
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
}

#[derive(Deserialize)]
struct AnthropicContent {
    text: Option<String>,
}

#[derive(Deserialize)]
struct AnthropicUsage {
    input_tokens: Option<i64>,
    output_tokens: Option<i64>,
}

#[async_trait]
impl AiProvider for AnthropicProvider {
    async fn chat(&self, request: ChatRequest) -> Result<ChatResponse, String> {
        let system_msg = request.messages.iter()
            .find(|m| m.role == "system")
            .map(|m| m.content.clone());

        let messages: Vec<serde_json::Value> = request.messages.iter()
            .filter(|m| m.role != "system")
            .map(|m| serde_json::json!({"role": m.role, "content": m.content}))
            .collect();

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

        let content = api_response.content
            .first()
            .and_then(|c| c.text.clone())
            .unwrap_or_default();

        Ok(ChatResponse {
            content,
            model: api_response.model.unwrap_or(request.model),
            usage: api_response.usage.map(|u| TokenUsage {
                prompt_tokens: u.input_tokens,
                completion_tokens: u.output_tokens,
            }),
        })
    }

    fn name(&self) -> &str {
        "anthropic"
    }
}

/// Provider that uses Claude Code's OAuth credentials from ~/.claude/.credentials.json.
/// This lets users with Claude Pro/Max subscriptions use their subscription for API calls.
pub struct ClaudeOAuthProvider {
    client: reqwest::Client,
}

#[derive(Deserialize)]
struct CredentialsFile {
    #[serde(rename = "claudeAiOauth")]
    claude_ai_oauth: Option<OAuthCredentials>,
}

#[derive(Deserialize, Clone)]
struct OAuthCredentials {
    #[serde(rename = "accessToken")]
    access_token: String,
    #[serde(rename = "refreshToken")]
    refresh_token: String,
    #[serde(rename = "expiresAt")]
    expires_at: u64,
}

impl ClaudeOAuthProvider {
    pub fn new() -> Result<Self, String> {
        // Verify credentials file exists
        let creds_path = Self::credentials_path()?;
        if !creds_path.exists() {
            return Err("Claude Code not logged in. Run 'claude' in terminal and log in first.".to_string());
        }
        Ok(Self {
            client: reqwest::Client::new(),
        })
    }

    fn credentials_path() -> Result<std::path::PathBuf, String> {
        let home = std::env::var("HOME").map_err(|_| "HOME not set")?;
        Ok(std::path::PathBuf::from(home).join(".claude").join(".credentials.json"))
    }

    fn read_credentials() -> Result<OAuthCredentials, String> {
        let path = Self::credentials_path()?;
        let data = std::fs::read_to_string(&path)
            .map_err(|e| format!("Failed to read credentials: {}", e))?;
        let file: CredentialsFile = serde_json::from_str(&data)
            .map_err(|e| format!("Failed to parse credentials: {}", e))?;
        file.claude_ai_oauth
            .ok_or("No OAuth credentials found. Run 'claude' and log in.".to_string())
    }

    async fn get_access_token(&self) -> Result<String, String> {
        let creds = Self::read_credentials()?;

        // Check if token is expired (with 60s buffer)
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;

        if creds.expires_at > now_ms + 60_000 {
            return Ok(creds.access_token);
        }

        // Token expired — refresh it
        log::info!("OAuth token expired, refreshing...");
        let resp = self.client
            .post("https://platform.claude.com/v1/oauth/token")
            .form(&[
                ("grant_type", "refresh_token"),
                ("refresh_token", &creds.refresh_token),
            ])
            .send()
            .await
            .map_err(|e| format!("Token refresh failed: {}", e))?;

        if !resp.status().is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(format!("Token refresh failed: {}", body));
        }

        let new_creds: serde_json::Value = resp.json().await
            .map_err(|e| format!("Failed to parse refresh response: {}", e))?;

        let new_token = new_creds["access_token"].as_str()
            .ok_or("No access_token in refresh response")?
            .to_string();

        // Update credentials file
        if let Ok(path) = Self::credentials_path() {
            if let Ok(data) = std::fs::read_to_string(&path) {
                if let Ok(mut file) = serde_json::from_str::<serde_json::Value>(&data) {
                    if let Some(oauth) = file.get_mut("claudeAiOauth") {
                        oauth["accessToken"] = serde_json::json!(&new_token);
                        if let Some(exp) = new_creds["expires_at"].as_u64()
                            .or_else(|| new_creds["expires_in"].as_u64().map(|s| now_ms + s * 1000))
                        {
                            oauth["expiresAt"] = serde_json::json!(exp);
                        }
                        let _ = std::fs::write(&path, serde_json::to_string_pretty(&file).unwrap_or_default());
                    }
                }
            }
        }

        Ok(new_token)
    }
}

#[async_trait]
impl AiProvider for ClaudeOAuthProvider {
    async fn chat(&self, request: ChatRequest) -> Result<ChatResponse, String> {
        let token = self.get_access_token().await?;

        let system_msg = request.messages.iter()
            .find(|m| m.role == "system")
            .map(|m| m.content.clone());

        let messages: Vec<serde_json::Value> = request.messages.iter()
            .filter(|m| m.role != "system")
            .map(|m| serde_json::json!({"role": m.role, "content": m.content}))
            .collect();

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

        let response = self.client
            .post("https://api.anthropic.com/v1/messages")
            .header("Authorization", format!("Bearer {}", token))
            .header("anthropic-version", "2023-06-01")
            .header("content-type", "application/json")
            .json(&body)
            .send()
            .await
            .map_err(|e| format!("Anthropic request failed: {}", e))?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            return Err(format!("Anthropic API error ({}): {}", status, body));
        }

        let api_response: AnthropicResponse = response
            .json()
            .await
            .map_err(|e| format!("Failed to parse Anthropic response: {}", e))?;

        let content = api_response.content
            .first()
            .and_then(|c| c.text.clone())
            .unwrap_or_default();

        Ok(ChatResponse {
            content,
            model: api_response.model.unwrap_or(request.model),
            usage: api_response.usage.map(|u| TokenUsage {
                prompt_tokens: u.input_tokens,
                completion_tokens: u.output_tokens,
            }),
        })
    }

    fn name(&self) -> &str {
        "anthropic"
    }
}

pub fn create_provider(
    settings: &AiSettings,
    model_state: Option<SharedModelState>,
) -> Result<Box<dyn AiProvider>, String> {
    let api_key = settings.api_key.as_deref();
    let endpoint = settings.endpoint.as_deref();

    match settings.provider.as_str() {
        "local" => {
            let model_path = settings
                .local_model_path
                .as_deref()
                .ok_or("No local model selected. Go to Settings to download one.")?;
            let gpu_layers = settings.local_gpu_layers.unwrap_or(-1);
            let state = model_state
                .ok_or("Local model state not available")?;
            Ok(Box::new(super::local_provider::LocalLlmProvider::new(
                model_path, gpu_layers, state,
            )))
        }
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
            if key.starts_with("sk-ant-oat") {
                // OAuth token — use Claude Code's credentials for Bearer auth
                Ok(Box::new(ClaudeOAuthProvider::new()?))
            } else {
                Ok(Box::new(AnthropicProvider::new(key)))
            }
        }
        "custom" => {
            let ep = endpoint.ok_or("Custom provider requires an endpoint URL")?;
            Ok(Box::new(OpenAiCompatibleProvider::new(ep, api_key, "custom")))
        }
        _ => Err(format!("Unknown AI provider: {}", settings.provider)),
    }
}
