use async_trait::async_trait;
use tauri::{AppHandle, Runtime};
use tauri_plugin_skim_ai::{CompleteArgs, SkimAiExt};

use super::provider::{AiProvider, ChatMessage, ChatRequest, ChatResponse};

/// Adapter for the Apple-platform MLX and Foundation Models plugin. Keeping this
/// behind `AiProvider` lets all normal command paths share provider routing.
pub struct NativePluginProvider<R: Runtime> {
    app: AppHandle<R>,
    provider: String,
}

impl<R: Runtime> NativePluginProvider<R> {
    pub fn new(app: AppHandle<R>, provider: impl Into<String>) -> Self {
        Self {
            app,
            provider: provider.into(),
        }
    }
}

fn complete_args(provider: &str, request: &ChatRequest) -> CompleteArgs {
    let user = request
        .messages
        .iter()
        .filter(|message| message.role != "system")
        .map(format_message)
        .collect::<Vec<_>>()
        .join("\n\n");
    CompleteArgs {
        system: request
            .messages
            .iter()
            .find(|message| message.role == "system")
            .map(|message| message.content.clone())
            .unwrap_or_default(),
        user,
        repo_id: (provider == "mlx").then(|| request.model.clone()),
        max_tokens: request
            .max_tokens
            .map(|value| value.clamp(1, u32::MAX as i64) as u32),
        json_mode: Some(request.json_mode),
    }
}

fn format_message(message: &ChatMessage) -> String {
    let content = message
        .content_blocks
        .as_ref()
        .map(|blocks| {
            blocks
                .iter()
                .filter_map(|block| block.get("text").and_then(serde_json::Value::as_str))
                .collect::<Vec<_>>()
                .join("\n")
        })
        .filter(|text| !text.is_empty())
        .unwrap_or_else(|| message.content.clone());
    format!("{}: {}", message.role, content)
}

fn native_error(provider: &str, error: impl ToString) -> String {
    let message = error.to_string();
    let lower = message.to_lowercase();
    if lower.contains("unavailable")
        || lower.contains("not downloaded")
        || lower.contains("no model")
    {
        format!("[configure-ai] {provider} on-device model unavailable: {message}")
    } else {
        message
    }
}

#[async_trait]
impl<R: Runtime> AiProvider for NativePluginProvider<R> {
    async fn chat(&self, request: ChatRequest) -> Result<ChatResponse, String> {
        let args = complete_args(&self.provider, &request);
        let app = self.app.clone();
        let provider = self.provider.clone();
        let raw = tokio::task::spawn_blocking(move || {
            let plugin = app.skim_ai();
            if provider == "mlx" {
                plugin
                    .mlx_complete(args)
                    .map_err(|error| native_error("MLX", error))
            } else {
                plugin
                    .fm_complete(args)
                    .map_err(|error| native_error("Foundation Models", error))
            }
        })
        .await
        .map_err(|error| format!("On-device AI task failed: {error}"))??;
        Ok(ChatResponse {
            content: raw,
            model: request.model,
            usage: None,
            tool_uses: Vec::new(),
            stop_reason: None,
        })
    }

    fn name(&self) -> &str {
        &self.provider
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_plugin_request_with_history_json_and_token_limit() {
        let request = ChatRequest {
            model: "mlx-community/test".into(),
            messages: vec![
                ChatMessage::text("system", "Be concise"),
                ChatMessage::text("user", "First"),
                ChatMessage::text("assistant", "Second"),
            ],
            temperature: Some(0.2),
            max_tokens: Some(120),
            json_mode: true,
            tools: None,
        };
        let args = complete_args("mlx", &request);
        assert_eq!(args.system, "Be concise");
        assert_eq!(args.user, "user: First\n\nassistant: Second");
        assert_eq!(args.repo_id.as_deref(), Some("mlx-community/test"));
        assert_eq!(args.max_tokens, Some(120));
        assert_eq!(args.json_mode, Some(true));
    }

    #[test]
    fn flattens_content_blocks_for_foundation_models_without_repo_id() {
        let mut message = ChatMessage::text("user", "fallback");
        message.content_blocks = Some(vec![serde_json::json!({"type": "text", "text": "block"})]);
        let request = ChatRequest {
            model: "foundation-model".into(),
            messages: vec![message],
            temperature: None,
            max_tokens: None,
            json_mode: false,
            tools: None,
        };
        let args = complete_args("foundation-models", &request);
        assert_eq!(args.user, "user: block");
        assert_eq!(args.repo_id, None);
    }

    #[test]
    fn marks_missing_native_models_as_setup_errors() {
        assert!(native_error("MLX", "model not downloaded").starts_with("[configure-ai]"));
        assert_eq!(
            native_error("MLX", "request timed out"),
            "request timed out"
        );
        assert_eq!(native_error("MLX", "model inference timed out"), "model inference timed out");
    }
}
