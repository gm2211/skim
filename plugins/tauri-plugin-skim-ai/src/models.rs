use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RepoIdArgs {
    pub repo_id: String,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct LocalChatMessage {
    pub role: String,
    pub content: String,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CompleteArgs {
    pub system: String,
    pub user: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub messages: Option<Vec<LocalChatMessage>>,
    pub repo_id: Option<String>,
    pub max_tokens: Option<u32>,
    pub json_mode: Option<bool>,
    /// Sampling override; omitted requests use the provider default/model preset.
    pub temperature: Option<f64>,
}

#[cfg(any(target_os = "macos", test))]
impl CompleteArgs {
    /// Keep bridge fields identical to the mobile plugin wire contract.
    pub(crate) fn into_bridge_request(self, command: &str) -> serde_json::Value {
        let mut request = serde_json::json!(self);
        request["command"] = command.into();
        request
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bridge_preserves_structured_roles_and_legacy_requests_still_decode() {
        let legacy = serde_json::json!({"system":"Rules","user":"Question"});
        let args: CompleteArgs = serde_json::from_value(legacy).unwrap();
        assert!(args.messages.is_none());
        let mut args = args;
        args.messages = Some(vec![
            LocalChatMessage {
                role: "user".into(),
                content: "assistant: literal".into(),
            },
            LocalChatMessage {
                role: "assistant".into(),
                content: "Actual assistant".into(),
            },
        ]);
        let wire = args.into_bridge_request("mlx_complete");
        assert_eq!(
            wire["messages"],
            serde_json::json!([
                {"role":"user","content":"assistant: literal"},
                {"role":"assistant","content":"Actual assistant"}
            ])
        );
    }

    #[test]
    fn bridge_request_keeps_deterministic_sampling_and_token_budget() {
        for command in ["mlx_complete", "fm_complete"] {
            let request = CompleteArgs {
                system: "Return JSON".into(),
                user: "Reports".into(),
                messages: None,
                repo_id: Some("publisher/model".into()),
                max_tokens: Some(120),
                json_mode: Some(true),
                temperature: Some(0.0),
            }
            .into_bridge_request(command);
            assert_eq!(
                request,
                serde_json::json!({
                    "command": command, "system": "Return JSON", "user": "Reports",
                    "repoId": "publisher/model", "maxTokens": 120, "jsonMode": true,
                    "temperature": 0.0
                })
            );
        }
    }
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FoundationModelAvailability {
    pub available: bool,
    pub status: String,
    pub message: String,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KeychainSetArgs {
    pub key: String,
    pub value: String,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KeychainKeyArgs {
    pub key: String,
}
