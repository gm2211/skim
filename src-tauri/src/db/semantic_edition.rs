//! Bounded, configured-provider planning. Invalid output never removes a story.
use super::story_policy;
use crate::ai::provider::{AiProvider, ChatMessage, ChatRequest};
use serde::Deserialize;
use std::time::Duration;

#[derive(Debug, Clone)]
pub struct SemanticGroup {
    pub members: Vec<usize>,
    pub importance: f64,
    pub confidence: f64,
    pub reason: String,
}

#[derive(Deserialize)]
struct Response {
    groups: Vec<serde_json::Value>,
}

pub fn parse(content: &str, count: usize) -> Option<Vec<SemanticGroup>> {
    let response: Response =
        serde_json::from_str(crate::commands::ai::extract_json_object(content).unwrap_or(content))
            .ok()?;
    let mut assigned = vec![0u8; count];
    let mut groups = Vec::new();
    for value in response.groups {
        let Some(members) = value
            .get("members")
            .and_then(|v| v.as_array())
            .and_then(|values| {
                values
                    .iter()
                    .map(|v| v.as_f64())
                    .collect::<Option<Vec<_>>>()
            })
        else {
            continue;
        };
        let Some(importance) = value.get("importance").and_then(|v| v.as_f64()) else {
            continue;
        };
        let Some(confidence) = value.get("confidence").and_then(|v| v.as_f64()) else {
            continue;
        };
        let Some(reason) = value
            .get("reason")
            .and_then(|v| v.as_str())
            .filter(|s| !s.trim().is_empty() && s.chars().count() <= 280)
        else {
            continue;
        };
        if !story_policy::valid_semantic_group(&members, count, &assigned, importance, confidence) {
            continue;
        }
        let members: Vec<usize> = members.into_iter().map(|n| n as usize).collect();
        for &index in &members {
            assigned[index] = 1;
        }
        groups.push(SemanticGroup {
            members,
            importance,
            confidence,
            reason: reason.trim().into(),
        });
    }
    (!groups.is_empty()).then_some(groups)
}

pub fn eligible_count(count: usize) -> bool {
    count > 0 && count <= story_policy::semantic_max_candidates()
}

pub async fn plan(
    provider: Option<&dyn AiProvider>,
    model: &str,
    listing: String,
    count: usize,
) -> Option<Vec<SemanticGroup>> {
    plan_with_timeout(provider, model, listing, count, Duration::from_secs(30)).await
}

async fn plan_with_timeout(
    provider: Option<&dyn AiProvider>,
    model: &str,
    listing: String,
    count: usize,
    timeout: Duration,
) -> Option<Vec<SemanticGroup>> {
    let provider = provider?;
    if !eligible_count(count) {
        return None;
    }
    let foundation_models = provider.name() == "foundation-models";
    // NativePluginProvider prefixes the user message with "user: ". Reserve
    // that transport overhead in addition to the same native input budget.
    if foundation_models
        && story_policy::semantic_prompt().len() + listing.len() + "user: ".len() > 2400
    {
        return None;
    }
    let request = ChatRequest {
        model: model.into(),
        messages: vec![
            ChatMessage {
                role: "system".into(),
                content: story_policy::semantic_prompt().into(),
                content_blocks: None,
            },
            ChatMessage {
                role: "user".into(),
                content: listing,
                content_blocks: None,
            },
        ],
        temperature: Some(0.0),
        max_tokens: Some(if foundation_models { 1400 } else { 8192 }),
        json_mode: true,
        tools: None,
    };
    let response = tokio::time::timeout(timeout, provider.chat(request))
        .await
        .ok()?
        .ok()?;
    parse(&response.content, count)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn recorded_local_model_failure_is_rejected() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../shared/fixtures/semantic-model-failure.json"
        ))
        .unwrap();
        assert!(parse(
            fixture["response"].as_str().unwrap(),
            fixture["candidate_count"].as_u64().unwrap() as usize
        )
        .is_none());
    }

    #[test]
    fn malformed_and_invalid_groups_leave_items_unassigned() {
        assert!(parse("not json", 3).is_none());
        assert!(parse(
            r#"{"groups":[{"members":[0,9],"importance":5,"confidence":1,"reason":"bad"}]}"#,
            3
        )
        .is_none());
        let result = parse(r#"{"groups":[{"members":[0,1],"importance":5,"confidence":1,"reason":"same event"},{"members":[1,2],"importance":5,"confidence":1,"reason":"overlap"}]}"#, 3).unwrap();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].members, vec![0, 1]);
    }
    struct NeverCalled;
    #[async_trait::async_trait]
    impl AiProvider for NeverCalled {
        async fn chat(&self, _: ChatRequest) -> Result<crate::ai::provider::ChatResponse, String> {
            panic!("oversized pool must not invoke AI")
        }
        fn name(&self) -> &str {
            "synthetic"
        }
    }
    struct FoundationBudget;
    #[async_trait::async_trait]
    impl AiProvider for FoundationBudget {
        async fn chat(
            &self,
            request: ChatRequest,
        ) -> Result<crate::ai::provider::ChatResponse, String> {
            assert_eq!(request.max_tokens, Some(1400));
            assert!(
                request
                    .messages
                    .iter()
                    .map(|message| message.content.len())
                    .sum::<usize>()
                    + 6
                    <= 2400
            );
            Err("synthetic budget check".into())
        }
        fn name(&self) -> &str {
            "foundation-models"
        }
    }
    #[tokio::test]
    async fn foundation_models_uses_utf8_budget_and_small_output_cap() {
        assert!(plan(Some(&FoundationBudget), "fake", "界".repeat(1000), 1)
            .await
            .is_none());
        assert!(plan(Some(&FoundationBudget), "fake", "[]".into(), 1)
            .await
            .is_none());
    }
    struct Pending;
    #[async_trait::async_trait]
    impl AiProvider for Pending {
        async fn chat(&self, _: ChatRequest) -> Result<crate::ai::provider::ChatResponse, String> {
            std::future::pending().await
        }
        fn name(&self) -> &str {
            "synthetic"
        }
    }
    struct Malformed;
    #[async_trait::async_trait]
    impl AiProvider for Malformed {
        async fn chat(&self, _: ChatRequest) -> Result<crate::ai::provider::ChatResponse, String> {
            Ok(crate::ai::provider::ChatResponse {
                content: "not JSON".into(),
                model: "fake".into(),
                usage: None,
                tool_uses: vec![],
                stop_reason: None,
            })
        }
        fn name(&self) -> &str {
            "synthetic"
        }
    }
    struct Failing;
    #[async_trait::async_trait]
    impl AiProvider for Failing {
        async fn chat(&self, _: ChatRequest) -> Result<crate::ai::provider::ChatResponse, String> {
            Err("offline".into())
        }
        fn name(&self) -> &str {
            "synthetic"
        }
    }
    #[tokio::test]
    async fn disabled_and_failed_provider_fall_back() {
        assert!(plan(Some(&NeverCalled), "fake", "".into(), 65)
            .await
            .is_none());
        assert!(plan(Some(&Malformed), "fake", "".into(), 2).await.is_none());
        assert!(plan_with_timeout(
            Some(&Pending),
            "fake",
            "".into(),
            2,
            Duration::from_millis(1)
        )
        .await
        .is_none());
        assert!(plan(None, "", "".into(), 2).await.is_none());
        assert!(plan(Some(&Failing), "fake", "".into(), 2).await.is_none());
    }
}
