//! ChatGPT Plus/Pro through Sign in with ChatGPT (`chatgpt_oauth.rs`): the public
//! Responses API with `store: false` and `stream: true`, read until
//! `response.completed`. Plan usage refuses `temperature`, `max_output_tokens`, and
//! other sampling parameters, so none are sent. Tools aren't wired: the chat
//! tool loop is Anthropic-only, and other providers drop tools the same way.

use super::provider::{AiProvider, ChatRequest, ChatResponse};
use async_trait::async_trait;
use futures_util::StreamExt;

pub const RESPONSES_URL: &str = "https://api.openai.com/v1/responses";
pub const MODELS_URL: &str = "https://api.openai.com/v1/models";

pub struct ChatGptSubscriptionProvider {
    client: reqwest::Client,
    token: String,
}

impl ChatGptSubscriptionProvider {
    pub fn new(token: String) -> Self {
        Self { client: reqwest::Client::new(), token }
    }
}

/// Whether a stored model id could be a ChatGPT plan model rather than one left
/// behind by another provider.
pub fn is_chatgpt_model(model: &str) -> bool {
    !model.is_empty() && !model.starts_with("claude") && !model.starts_with("grok") && model != "sonnet" && !model.contains('/')
}

/// `{instructions, input}` for a chat: system messages become instructions, the
/// rest the conversation.
pub fn request_body(request: &ChatRequest, model: &str) -> serde_json::Value {
    let instructions = request
        .messages
        .iter()
        .filter(|m| m.role == "system")
        .map(|m| m.content.as_str())
        .collect::<Vec<_>>()
        .join("\n\n");
    let input: Vec<serde_json::Value> = request
        .messages
        .iter()
        .filter(|m| m.role != "system")
        .map(|m| {
            let assistant = m.role == "assistant";
            serde_json::json!({
                "role": if assistant { "assistant" } else { "user" },
                "content": [{"type": if assistant { "output_text" } else { "input_text" }, "text": m.content}],
            })
        })
        .collect();
    serde_json::json!({
        "model": model,
        "instructions": instructions,
        "input": input,
        "store": false,
        "stream": true,
    })
}

/// Accumulates a Responses event stream.
#[derive(Default)]
pub struct ResponsesStream {
    pub text: String,
    pub completed: bool,
}

impl ResponsesStream {
    /// Takes one SSE line; Ok(true) once the response is complete.
    pub fn consume(&mut self, line: &str) -> Result<bool, String> {
        let Some(payload) = line.strip_prefix("data:").map(str::trim) else { return Ok(false) };
        let Ok(event) = serde_json::from_str::<serde_json::Value>(payload) else { return Ok(false) };
        let response = event.get("response");
        match event.get("type").and_then(|t| t.as_str()) {
            Some("response.output_text.delta") => {
                self.text.push_str(event.get("delta").and_then(|d| d.as_str()).unwrap_or(""));
            }
            Some("response.completed") | Some("response.incomplete") => {
                if self.text.is_empty() {
                    self.text = response.map(output_text).unwrap_or_default();
                }
                if self.text.is_empty() && event["type"] == "response.incomplete" {
                    let reason = response
                        .and_then(|r| r.pointer("/incomplete_details/reason"))
                        .and_then(|r| r.as_str())
                        .map(|r| format!(" ({r})"))
                        .unwrap_or_default();
                    return Err(format!("ChatGPT stopped before answering{reason}."));
                }
                self.completed = true;
                return Ok(true);
            }
            Some("response.failed") => {
                let error = response.and_then(|r| r.get("error"));
                return Err(friendly_error(
                    error.and_then(|e| e.get("code")).and_then(|c| c.as_str()),
                    error.and_then(|e| e.get("message")).and_then(|m| m.as_str()),
                ));
            }
            Some("error") => {
                let error = event.get("error").unwrap_or(&event);
                return Err(friendly_error(
                    error.get("code").and_then(|c| c.as_str()),
                    error.get("message").and_then(|m| m.as_str()),
                ));
            }
            _ => {}
        }
        Ok(false)
    }

    pub fn finish(self) -> Result<String, String> {
        if !self.completed {
            return Err("ChatGPT's answer was cut off. Try again.".into());
        }
        let text = self.text.trim().to_string();
        if text.is_empty() {
            return Err("The ChatGPT response was empty.".into());
        }
        Ok(text)
    }
}

pub fn output_text(response: &serde_json::Value) -> String {
    response
        .get("output")
        .and_then(|o| o.as_array())
        .into_iter()
        .flatten()
        .filter_map(|item| item.get("content").and_then(|c| c.as_array()))
        .flatten()
        .filter(|part| part.get("type").and_then(|t| t.as_str()) == Some("output_text"))
        .filter_map(|part| part.get("text").and_then(|t| t.as_str()))
        .collect()
}

pub fn friendly_error(code: Option<&str>, message: Option<&str>) -> String {
    match code {
        Some("subscription_sharing_usage_limit_exceeded") => {
            "Your ChatGPT plan's limit for Skim is used up. Raise it in ChatGPT's usage settings or wait for it to reset.".into()
        }
        Some("subscription_sharing_user_not_eligible") => {
            "This ChatGPT account's plan can't be used in other apps. Plus and Pro plans can.".into()
        }
        Some("subscription_sharing_usage_unavailable") | Some("subscription_sharing_user_unavailable") => {
            "ChatGPT plan usage is unavailable right now. Try again shortly.".into()
        }
        Some("subscription_sharing_invalid_user")
        | Some("chatpass_v2_scope_not_authorized")
        | Some("chatpass_v2_invalid_authorization_context") => {
            "[configure-ai] ChatGPT needs you to sign in again.".into()
        }
        _ => match message.filter(|m| !m.trim().is_empty()) {
            Some(m) => format!("ChatGPT couldn't run this request: {}", m.chars().take(240).collect::<String>()),
            None => "ChatGPT couldn't run this request. Try again.".into(),
        },
    }
}

fn http_error(status: u16, body: &str) -> String {
    let v: serde_json::Value = serde_json::from_str(body).unwrap_or_default();
    let code = v.pointer("/error/code").and_then(|c| c.as_str());
    let message = v.pointer("/error/message").or_else(|| v.get("detail")).and_then(|m| m.as_str());
    if code.is_some() {
        return friendly_error(code, message);
    }
    match status {
        401 => "[configure-ai] ChatGPT sign-in expired. Sign in again in Settings.".into(),
        429 => friendly_error(Some("subscription_sharing_usage_limit_exceeded"), None),
        500..=599 => "ChatGPT is temporarily unavailable. Try again shortly.".into(),
        _ => friendly_error(None, message),
    }
}

/// Plan-usage model lists come as `{"models":[{slug, display_name, visibility}]}`;
/// only `visibility == "list"` belongs in a picker. Returns `(id, display name)`.
pub fn parse_models(body: &str) -> Vec<(String, String)> {
    let v: serde_json::Value = serde_json::from_str(body).unwrap_or_default();
    if let Some(models) = v.get("models").and_then(|m| m.as_array()) {
        return models
            .iter()
            .filter(|m| m.get("visibility").and_then(|v| v.as_str()).map_or(true, |v| v == "list"))
            .filter_map(|m| {
                let slug = m.get("slug").and_then(|s| s.as_str()).filter(|s| !s.is_empty())?;
                let name = m.get("display_name").and_then(|s| s.as_str()).filter(|s| !s.is_empty()).unwrap_or(slug);
                Some((slug.to_string(), name.to_string()))
            })
            .collect();
    }
    v.get("data")
        .and_then(|d| d.as_array())
        .into_iter()
        .flatten()
        .filter_map(|m| m.get("id").and_then(|s| s.as_str()).map(|id| (id.to_string(), id.to_string())))
        .collect()
}

pub async fn list_models(client: &reqwest::Client, token: &str) -> Result<Vec<(String, String)>, String> {
    let resp = client
        .get(MODELS_URL)
        .bearer_auth(token)
        .timeout(std::time::Duration::from_secs(15))
        .send()
        .await
        .map_err(|e| format!("Could not reach ChatGPT: {e}"))?;
    let status = resp.status().as_u16();
    let body = resp.text().await.unwrap_or_default();
    if !(200..300).contains(&status) {
        return Err(http_error(status, &body));
    }
    Ok(parse_models(&body))
}

#[async_trait]
impl AiProvider for ChatGptSubscriptionProvider {
    async fn chat(&self, request: ChatRequest) -> Result<ChatResponse, String> {
        let model = if is_chatgpt_model(&request.model) {
            request.model.clone()
        } else {
            list_models(&self.client, &self.token)
                .await?
                .into_iter()
                .next()
                .map(|(id, _)| id)
                .ok_or("Your ChatGPT plan lists no models Skim can use.")?
        };
        let resp = self
            .client
            .post(RESPONSES_URL)
            .bearer_auth(&self.token)
            .header("Accept", "text/event-stream")
            .json(&request_body(&request, &model))
            .send()
            .await
            .map_err(|e| format!("AI request failed: {e}"))?;
        let status = resp.status().as_u16();
        if !(200..300).contains(&status) {
            let body = resp.text().await.unwrap_or_default();
            log::warn!("ChatGPT request failed ({status}): {}", body.chars().take(2000).collect::<String>());
            return Err(http_error(status, &body));
        }
        let mut stream = ResponsesStream::default();
        let mut bytes = resp.bytes_stream();
        let mut pending = String::new();
        'read: while let Some(chunk) = bytes.next().await {
            let chunk = chunk.map_err(|e| format!("ChatGPT stream failed: {e}"))?;
            pending.push_str(&String::from_utf8_lossy(&chunk));
            while let Some(end) = pending.find('\n') {
                let line: String = pending.drain(..=end).collect();
                if stream.consume(line.trim_end_matches(['\r', '\n']))? {
                    break 'read;
                }
            }
        }
        if !stream.completed && !pending.is_empty() {
            stream.consume(pending.trim_end())?;
        }
        Ok(ChatResponse {
            content: stream.finish()?,
            model,
            usage: None,
            tool_uses: Vec::new(),
            stop_reason: None,
        })
    }

    fn name(&self) -> &str {
        "chatgpt-subscription"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ai::provider::ChatMessage;

    #[test]
    fn request_is_streamed_unstored_and_unsampled() {
        let request = ChatRequest {
            model: "gpt-x".into(),
            messages: vec![
                ChatMessage::text("system", "be brief"),
                ChatMessage::text("user", "hi"),
                ChatMessage::text("assistant", "hello"),
            ],
            temperature: Some(0.3),
            max_tokens: Some(100),
            json_mode: false,
            tools: None,
        };
        let body = request_body(&request, "gpt-x");
        assert_eq!(body["store"], false);
        assert_eq!(body["stream"], true);
        assert_eq!(body["instructions"], "be brief");
        assert!(body.get("temperature").is_none());
        assert!(body.get("max_output_tokens").is_none());
        assert_eq!(body["input"].as_array().unwrap().len(), 2);
        assert_eq!(body["input"][1]["content"][0]["type"], "output_text");
    }

    #[test]
    fn stream_collects_text_until_completed() {
        let mut s = ResponsesStream::default();
        assert!(!s.consume("event: response.output_text.delta").unwrap());
        assert!(!s.consume(r#"data: {"type":"response.output_text.delta","delta":"Hel"}"#).unwrap());
        assert!(!s.consume(r#"data: {"type":"response.output_text.delta","delta":"lo"}"#).unwrap());
        assert!(s.consume(r#"data: {"type":"response.completed","response":{"output":[]}}"#).unwrap());
        assert_eq!(s.finish().unwrap(), "Hello");

        let mut cut = ResponsesStream::default();
        cut.consume(r#"data: {"type":"response.output_text.delta","delta":"Hel"}"#).unwrap();
        assert!(cut.finish().is_err());
    }

    #[test]
    fn completed_without_deltas_reads_the_output() {
        let mut s = ResponsesStream::default();
        s.consume(r#"data: {"type":"response.completed","response":{"output":[{"type":"message","content":[{"type":"output_text","text":"Hi"}]}]}}"#).unwrap();
        assert_eq!(s.finish().unwrap(), "Hi");
    }

    #[test]
    fn usage_limit_reads_as_a_plan_limit() {
        let mut s = ResponsesStream::default();
        let err = s
            .consume(r#"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"x"}}}"#)
            .unwrap_err();
        assert!(err.contains("limit for Skim"));
    }

    #[test]
    fn model_list_keeps_listed_models() {
        let body = r#"{"models":[{"slug":"gpt-a","display_name":"GPT A","visibility":"list"},{"slug":"gpt-hidden","visibility":"hide"}]}"#;
        assert_eq!(parse_models(body), vec![("gpt-a".to_string(), "GPT A".to_string())]);
    }

    #[test]
    fn foreign_models_are_not_chatgpt_models() {
        for m in ["", "claude-sonnet-5", "grok-4.3", "openai/gpt-4o", "sonnet"] {
            assert!(!is_chatgpt_model(m), "{m}");
        }
        assert!(is_chatgpt_model("gpt-5.5"));
    }
}
