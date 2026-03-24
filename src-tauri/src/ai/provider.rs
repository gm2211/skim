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

        let body = serde_json::json!({
            "model": request.model,
            "messages": request.messages,
            "temperature": request.temperature.unwrap_or(0.3),
            "max_tokens": request.max_tokens.unwrap_or(2048),
        });

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
        "lmstudio" => Ok(Box::new(OpenAiCompatibleProvider::new(
            endpoint.unwrap_or("http://localhost:1234"),
            None,
            "lmstudio",
        ))),
        "llamacpp" => Ok(Box::new(OpenAiCompatibleProvider::new(
            endpoint.unwrap_or("http://localhost:8080"),
            None,
            "llamacpp",
        ))),
        "groq" => Ok(Box::new(OpenAiCompatibleProvider::new(
            "https://api.groq.com/openai",
            api_key,
            "groq",
        ))),
        "custom" => {
            let ep = endpoint.ok_or("Custom provider requires an endpoint URL")?;
            Ok(Box::new(OpenAiCompatibleProvider::new(ep, api_key, "custom")))
        }
        _ => Err(format!("Unknown AI provider: {}", settings.provider)),
    }
}
