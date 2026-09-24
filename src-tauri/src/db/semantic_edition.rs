//! Bounded, configured-provider planning. Invalid output never removes a story.
use super::story_policy;
use crate::ai::provider::{AiProvider, ChatMessage, ChatRequest};
use std::time::Duration;

#[derive(Debug, Clone)]
pub struct SemanticGroup {
    pub members: Vec<usize>,
    pub importance: f64,
    pub confidence: f64,
    pub reason: String,
}

pub fn parse(content: &str, count: usize) -> Option<Vec<SemanticGroup>> {
    let response = whole_json(content)?;
    let values = response.as_array().or_else(|| response.get("groups")?.as_array())?;
    let mut assigned = vec![0u8; count];
    let mut groups = Vec::new();
    for value in values {
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
    // One deadline spans all calls. Once membership is verified, rating failure
    // can safely retain those groups with their independent base scores.
    let deadline = tokio::time::Instant::now() + timeout;
    let verified = tokio::time::timeout_at(
        deadline,
        verify_memberships(provider, model, listing.clone(), count),
    )
    .await
    .ok()??;
    if verified.rating_ids.is_empty() {
        return Some(verified.groups);
    }
    let mut rated = verified.groups.clone();
    // Isolate each event: unrelated events in the same rating request distorted
    // consequence ratings in local-model probes. Publish this stage atomically.
    for &id in &verified.rating_ids {
        let single = VerifiedPlan {
            groups: rated,
            rating_ids: vec![id],
        };
        let Some(payload) = rating_listing(&listing, count, &single) else {
            return Some(verified.groups);
        };
        let response = tokio::time::timeout_at(
            deadline,
            request(
                provider,
                model,
                story_policy::semantic_rating_prompt(),
                payload,
            ),
        )
        .await
        .ok()
        .flatten()
        .and_then(|raw| apply_ratings(&raw, &single));
        let Some(result) = response else {
            return Some(verified.groups);
        };
        rated = result;
    }
    Some(rated)
}

async fn request(
    provider: &dyn AiProvider,
    model: &str,
    prompt: &str,
    listing: String,
) -> Option<String> {
    let foundation_models = provider.name() == "foundation-models";
    if foundation_models && prompt.len() + listing.len() + "user: ".len() > 2400 {
        return None;
    }
    let response = provider
        .chat(ChatRequest {
            model: model.into(),
            messages: vec![
                ChatMessage {
                    role: "system".into(),
                    content: prompt.into(),
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
        })
        .await
        .ok()?;
    Some(response.content)
}

fn requested_pairs(groups: &[SemanticGroup]) -> Option<Vec<[usize; 2]>> {
    let mut pairs = std::collections::BTreeSet::new();
    for group in groups {
        for (offset, &left) in group.members.iter().enumerate() {
            for &right in &group.members[offset + 1..] {
                pairs.insert([left.min(right), left.max(right)]);
                if pairs.len() > story_policy::semantic_max_pairs() {
                    return None;
                }
            }
        }
    }
    Some(pairs.into_iter().collect())
}

fn report_listing(listing: &str, count: usize) -> Option<Vec<serde_json::Value>> {
    let candidates: Vec<serde_json::Value> = serde_json::from_str(listing).ok()?;
    if candidates.len() != count {
        return None;
    }
    let mut reports = Vec::with_capacity(count);
    for (index, candidate) in candidates.iter().enumerate() {
        if candidate.get("index")?.as_u64()? != index as u64 {
            return None;
        }
        let timestamp = candidate.get("timestamp")?.as_f64()?;
        if !timestamp.is_finite() {
            return None;
        }
        let date = chrono::DateTime::from_timestamp(timestamp.floor() as i64, 0)?
            .format("%Y-%m-%d")
            .to_string();
        reports.push(serde_json::json!({"index":index, "title":candidate.get("title")?.as_str()?, "excerpt":candidate.get("excerpt")?.as_str()?, "activity_date":date}));
    }
    Some(reports)
}

fn pair_listing(listing: &str, count: usize, pairs: &[[usize; 2]]) -> Option<String> {
    let reports = report_listing(listing, count)?;
    serde_json::to_string(&serde_json::json!({"reports":reports,"pairs":pairs})).ok()
}

fn whole_json(content: &str) -> Option<serde_json::Value> {
    let trimmed = content.trim();
    let unfenced = trimmed
        .strip_prefix("```json")
        .or_else(|| trimmed.strip_prefix("```"))
        .and_then(|text| text.trim().strip_suffix("```"))
        .unwrap_or(trimmed)
        .trim();
    serde_json::from_str(unfenced).ok()
}

fn pair_matrix(content: &str, count: usize, requested: &[[usize; 2]]) -> Option<Vec<u8>> {
    let decoded = whole_json(content)?;
    let results = decoded
        .as_array()
        .or_else(|| decoded.get("pairs")?.as_array())?;
    if results.len() != requested.len() {
        return None;
    }
    let expected: std::collections::BTreeSet<_> = requested.iter().copied().collect();
    let mut seen = std::collections::BTreeSet::new();
    let mut matrix = vec![0u8; count.checked_mul(count)?];
    for result in results {
        let members = match (result.get("members"), result.get("pair")) {
            (Some(members), None) | (None, Some(members)) => members.as_array()?,
            _ => return None,
        };
        if members.len() != 2 {
            return None;
        }
        let index = |value: &serde_json::Value| -> Option<usize> {
            let number = value.as_f64()?;
            (number.is_finite() && number >= 0.0 && number.fract() == 0.0 && number < count as f64)
                .then_some(number as usize)
        };
        let left = index(&members[0])?;
        let right = index(&members[1])?;
        let pair = [left.min(right), left.max(right)];
        if left == right || !expected.contains(&pair) || !seen.insert(pair) {
            return None;
        }
        let same_event = result.get("same_event")?.as_bool()?;
        let confidence = result.get("confidence")?.as_f64()?;
        if !confidence.is_finite() || !(0.0..=1.0).contains(&confidence) {
            return None;
        }
        if same_event && confidence >= 0.8 {
            matrix[left * count + right] = 1;
            matrix[right * count + left] = 1;
        }
    }
    (seen == expected).then_some(matrix)
}

struct VerifiedPlan {
    groups: Vec<SemanticGroup>,
    rating_ids: Vec<usize>,
}

fn rating_listing(listing: &str, count: usize, plan: &VerifiedPlan) -> Option<String> {
    let reports = report_listing(listing, count)?;
    let mut groups = Vec::new();
    for &id in &plan.rating_ids {
        let members = plan
            .groups
            .get(id)?
            .members
            .iter()
            .map(|&index| reports.get(index).cloned())
            .collect::<Option<Vec<_>>>()?;
        groups.push(serde_json::json!({"group_id":id, "reports":members}));
    }
    serde_json::to_string(&serde_json::json!({"groups":groups})).ok()
}

fn apply_ratings(content: &str, plan: &VerifiedPlan) -> Option<Vec<SemanticGroup>> {
    let response = whole_json(content)?;
    let ratings = response.get("ratings")?.as_array()?;
    if ratings.len() != plan.rating_ids.len() {
        return None;
    }
    let expected: std::collections::BTreeSet<_> = plan.rating_ids.iter().copied().collect();
    let mut seen = std::collections::BTreeSet::new();
    let mut result = plan.groups.clone();
    for rating in ratings {
        let number = rating.get("group_id")?.as_f64()?;
        if !number.is_finite()
            || number < 0.0
            || number.fract() != 0.0
            || number >= result.len() as f64
        {
            return None;
        }
        let id = number as usize;
        if !expected.contains(&id) || !seen.insert(id) {
            return None;
        }
        let importance = rating.get("importance")?.as_f64()?;
        let confidence = rating.get("confidence")?.as_f64()?;
        if !story_policy::valid_semantic_rating(importance, confidence) {
            return None;
        }
        let reason = rating.get("reason")?.as_str()?.trim();
        if reason.is_empty() || reason.chars().count() > 280 {
            return None;
        }
        result[id].importance = importance;
        result[id].confidence = confidence;
        result[id].reason = reason.into();
    }
    (seen == expected).then_some(result)
}

async fn verify_memberships(
    provider: &dyn AiProvider,
    model: &str,
    listing: String,
    count: usize,
) -> Option<VerifiedPlan> {
    let raw = request(
        provider,
        model,
        story_policy::semantic_prompt(),
        listing.clone(),
    )
    .await?;
    let groups = parse(&raw, count)?;
    let pairs = requested_pairs(&groups)?;
    if pairs.is_empty() {
        return Some(VerifiedPlan {
            groups,
            rating_ids: Vec::new(),
        });
    }
    let input = pair_listing(&listing, count, &pairs)?;
    let raw = request(provider, model, story_policy::semantic_pair_prompt(), input).await?;
    let matrix = pair_matrix(&raw, count, &pairs)?;
    let mut verified = Vec::new();
    let mut rating_ids = Vec::new();
    for group in groups {
        let partitions = story_policy::semantic_partition(&group.members, count, &matrix)?;
        let split = partitions.len() > 1;
        for members in partitions {
            if split {
                rating_ids.push(verified.len());
            }
            verified.push(SemanticGroup {
                members,
                importance: if split { 3.0 } else { group.importance },
                confidence: group.confidence,
                // Neutral adjustment until this specific verified event is rated.
                reason: if split {
                    "From your feeds".into()
                } else {
                    group.reason.clone()
                },
            });
        }
    }
    Some(VerifiedPlan {
        groups: verified,
        rating_ids,
    })
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
    fn complete_primary_arrays_preserve_validation_and_verification() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!("../../../shared/fixtures/semantic-primary-array.json")).unwrap();
        let raw = fixture["response"].as_str().unwrap();
        let groups = parse(raw, 45).unwrap();
        assert_eq!(groups.len(), 42);
        assert_eq!(requested_pairs(&groups).unwrap(), vec![[2, 4], [3, 17], [9, 18]]);
        assert_eq!(parse(&format!("```json\n{raw}\n```"), 45).unwrap().len(), 42);
        assert!(parse(&format!("{raw} trailing"), 45).is_none());
        assert!(parse(&raw[..raw.len() - 2], 45).is_none());
        assert!(parse(r#"{"members":[0],"importance":5,"confidence":1,"reason":"Bare group"}"#, 1).is_none());
        let mixed = r#"[{"members":[0,1],"importance":4,"confidence":1,"reason":"Valid"},{"members":[1,2],"importance":4,"confidence":1,"reason":"Overlap"},{"members":[true],"importance":5,"confidence":1,"reason":"Invalid identity"},{"members":[9],"importance":4,"confidence":1,"reason":"Foreign identity"}]"#;
        let validated = parse(mixed, 3).unwrap();
        assert_eq!(validated.len(), 1);
        assert_eq!(validated[0].members, vec![0, 1]);
        assert_eq!(requested_pairs(&validated).unwrap(), vec![[0, 1]]);
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
    fn listing(count: usize) -> String {
        serde_json::to_string(&(0..count).map(|index| serde_json::json!({"index":index,"title":format!("Report {index}"),"excerpt":"Source details","timestamp":1727136000.0,"baseScore":4.0})).collect::<Vec<_>>()).unwrap()
    }
    fn first_pass(members: Vec<usize>) -> String {
        serde_json::json!({"groups":[{"members":members,"importance":4,"confidence":0.95,"reason":"Original event assertion"}]}).to_string()
    }
    struct Scripted {
        replies: Vec<String>,
        requests: std::sync::Mutex<Vec<ChatRequest>>,
        delay: Duration,
    }
    impl Scripted {
        fn new(replies: Vec<String>) -> Self {
            Self {
                replies,
                requests: std::sync::Mutex::new(Vec::new()),
                delay: Duration::ZERO,
            }
        }
    }
    #[async_trait::async_trait]
    impl AiProvider for Scripted {
        async fn chat(
            &self,
            request: ChatRequest,
        ) -> Result<crate::ai::provider::ChatResponse, String> {
            let index = {
                let mut requests = self.requests.lock().unwrap();
                let index = requests.len();
                requests.push(request);
                index
            };
            tokio::time::sleep(self.delay).await;
            Ok(crate::ai::provider::ChatResponse {
                content: self
                    .replies
                    .get(index)
                    .ok_or("scripted provider has no more responses")?
                    .clone(),
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

    #[test]
    fn pair_answers_require_complete_unique_boolean_identities() {
        let requested = [[0, 1], [0, 2], [1, 2]];
        let valid = serde_json::json!([
            {"members":[0,1],"same_event":true,"confidence":0.9},
            {"members":[0,2],"same_event":false,"confidence":0.3},
            {"members":[2,1],"same_event":true,"confidence":1.0}
        ]);
        assert!(pair_matrix(&valid.to_string(), 3, &requested).is_some());
        assert!(pair_matrix(
            &serde_json::json!({"pairs":valid}).to_string(),
            3,
            &requested
        )
        .is_some());
        for replacement in [
            serde_json::json!({"members":[0,1],"same_event":true,"confidence":1}),
            serde_json::json!({"members":[0,3],"same_event":true,"confidence":1}),
            serde_json::json!({"members":[0,1.5],"same_event":true,"confidence":1}),
            serde_json::json!({"members":[0,2],"same_event":"false","confidence":1}),
            serde_json::json!({"members":[0,2],"same_event":true,"confidence":1.1}),
        ] {
            let mut invalid = valid.clone();
            invalid[1] = replacement;
            assert!(pair_matrix(&invalid.to_string(), 3, &requested).is_none());
        }
        assert!(pair_matrix("[]", 3, &requested).is_none());
        assert!(pair_matrix(r#"[{"same_event":true,"confidence":1}]"#, 2, &[[0, 1]]).is_none());
    }

    #[test]
    fn explicit_pair_alias_and_unknown_edges_are_conservative() {
        assert_eq!(
            pair_matrix(
                r#"[{"pair":[0,1],"same_event":true,"confidence":0.9}]"#,
                2,
                &[[0, 1]]
            )
            .unwrap(),
            vec![0, 1, 1, 0]
        );
        assert_eq!(
            pair_matrix(
                r#"[{"members":[0,1],"same_event":true,"confidence":0.79}]"#,
                2,
                &[[0, 1]]
            )
            .unwrap(),
            vec![0; 4]
        );
        for output in [
            r#"[{"pair":[0,1],"members":[0,1],"same_event":true,"confidence":1}]"#,
            r#"[{"pair":null,"members":[0,1],"same_event":true,"confidence":1}]"#,
            r#"[{"pair":[true,1],"same_event":true,"confidence":1}]"#,
        ] {
            assert!(pair_matrix(output, 2, &[[0, 1]]).is_none());
        }
    }

    #[tokio::test]
    async fn recorded_live_feed_pipeline_preserves_handles_and_independent_labels() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../shared/fixtures/semantic-live-feed-replay.json"
        )).unwrap();
        let candidates = fixture["candidates"].as_array().unwrap();
        let replies = fixture["responses"].as_array().unwrap().iter()
            .map(|value| value.as_str().unwrap().to_owned()).collect();
        let provider = Scripted::new(replies);
        let groups = plan(Some(&provider), fixture["model"].as_str().unwrap(),
            fixture["candidates"].to_string(), candidates.len()).await.unwrap();
        let handles: Vec<_> = groups.iter().flat_map(|group| group.members.iter().copied()).collect();
        assert_eq!(handles.len(), candidates.len(), "no duplicated or lost references");
        assert_eq!(handles.iter().copied().collect::<std::collections::BTreeSet<_>>(),
            (0..candidates.len()).collect());
        let group_for = |index: usize| groups.iter().position(|group| group.members.contains(&index)).unwrap();
        let labels = &fixture["editorial_labels"];
        for pair in labels["must_group_same_event_pairs"].as_array().unwrap() {
            let members = pair["members"].as_array().unwrap();
            assert_eq!(group_for(members[0].as_u64().unwrap() as usize),
                group_for(members[1].as_u64().unwrap() as usize), "independent same-event label {pair}");
        }
        for pair in labels["must_separate_different_event_pairs"].as_array().unwrap().iter()
            .map(|pair| &pair["members"])
            .chain(fixture["primary_false_group_separations"].as_array().unwrap().iter()) {
            assert_ne!(group_for(pair[0].as_u64().unwrap() as usize),
                group_for(pair[1].as_u64().unwrap() as usize), "distinct events {pair}");
        }
        for comparison in labels["importance_comparisons"].as_array().unwrap() {
            let higher = comparison["higher_index"].as_u64().unwrap() as usize;
            let lower = comparison["lower_index"].as_u64().unwrap() as usize;
            assert!(groups[group_for(higher)].importance > groups[group_for(lower)].importance,
                "independent consequence comparison {higher} > {lower}");
        }
        // Verify the complete production request protocol against the capture;
        // labels are evaluation-only and never enter any model request.
        let requests = provider.requests.lock().unwrap();
        let recorded = fixture["requests"].as_array().unwrap();
        assert_eq!(requests.len(), recorded.len());
        for (request, expected) in requests.iter().zip(recorded) {
            assert_eq!(request.model, expected["model"].as_str().unwrap());
            assert_eq!(request.temperature, Some(0.0));
            assert_eq!(request.max_tokens, Some(8192));
            assert!(request.json_mode);
            assert_eq!(request.messages.len(), 2);
            assert_eq!(request.messages[0].content, expected["messages"][0]["content"].as_str().unwrap());
            let actual: serde_json::Value = serde_json::from_str(&request.messages[1].content).unwrap();
            let expected: serde_json::Value = serde_json::from_str(expected["messages"][1]["content"].as_str().unwrap()).unwrap();
            assert_eq!(actual, expected);
        }
        // Unlabeled groupings are deliberately not asserted as editorial truth.
    }

    #[tokio::test]
    async fn recorded_configured_responses_pass_full_rating_pipeline() {
        let cases: serde_json::Value = serde_json::from_str(include_str!(
            "../../../shared/fixtures/semantic-verification-responses.json"
        ))
        .unwrap();
        for case in cases.as_array().unwrap() {
            let candidates = case["candidates"].as_array().unwrap();
            let mut replies = vec![
                case["primary_response"].as_str().unwrap().into(),
                case["verification_response"].as_str().unwrap().into(),
            ];
            replies.extend(
                case["rating_responses"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|r| r.as_str().unwrap().to_string()),
            );
            let expected_calls = replies.len();
            let provider = Scripted::new(replies);
            let result = plan(
                Some(&provider),
                case["model"].as_str().unwrap(),
                case["candidates"].to_string(),
                candidates.len(),
            )
            .await
            .unwrap();
            let mut actual: Vec<_> = result
                .iter()
                .map(|group| {
                    let mut members = group.members.clone();
                    members.sort();
                    members
                })
                .collect();
            actual.sort();
            let mut expected: Vec<Vec<usize>> =
                serde_json::from_value(case["expected_groups"].clone()).unwrap();
            for group in &mut expected {
                group.sort();
            }
            expected.sort();
            assert_eq!(actual, expected, "{}", case["name"]);
            let handles: std::collections::BTreeSet<usize> =
                actual.iter().flatten().copied().collect();
            assert_eq!(handles, (0..candidates.len()).collect(), "no lost handles");
            let importance = |index: usize| {
                result
                    .iter()
                    .find(|group| group.members.contains(&index))
                    .unwrap()
                    .importance
            };
            for constraint in case["importance_constraints"].as_array().unwrap() {
                for high in constraint["higher"].as_array().unwrap() {
                    for low in constraint["lower"].as_array().unwrap() {
                        assert!(
                            importance(high.as_u64().unwrap() as usize)
                                > importance(low.as_u64().unwrap() as usize),
                            "{} importance {} > {}",
                            case["name"],
                            high,
                            low
                        );
                    }
                }
            }
            let requests = provider.requests.lock().unwrap();
            assert_eq!(requests.len(), expected_calls);
            for request in requests.iter().skip(2) {
                let payload: serde_json::Value =
                    serde_json::from_str(&request.messages[1].content).unwrap();
                assert_eq!(
                    payload["groups"].as_array().unwrap().len(),
                    1,
                    "rating must isolate one event"
                );
                assert_eq!(
                    request.messages[0].content,
                    story_policy::semantic_rating_prompt()
                );
            }
            assert_eq!(
                requests[0].messages[0].content,
                story_policy::semantic_prompt()
            );
            assert_eq!(
                requests[1].messages[0].content,
                story_policy::semantic_pair_prompt()
            );
            assert_eq!(
                requests[0].messages[1].content,
                case["candidates"].to_string()
            );
            let second: serde_json::Value =
                serde_json::from_str(&requests[1].messages[1].content).unwrap();
            assert_eq!(second.as_object().unwrap().len(), 2);
            assert!(second.get("reports").is_some() && second.get("pairs").is_some());
            for report in second["reports"].as_array().unwrap() {
                assert_eq!(report.as_object().unwrap().len(), 4);
            }
        }
    }

    #[tokio::test]
    async fn split_events_receive_independent_consequence_ratings() {
        assert!(story_policy::valid_semantic_rating(5.0, 0.95));
        let provider = Scripted::new(vec![
            first_pass(vec![0, 1]),
            r#"{"pairs":[{"members":[0,1],"same_event":false,"confidence":1}]}"#.into(),
            r#"{"ratings":[{"group_id":0,"importance":5,"confidence":0.95,"reason":"Urgent public safety evacuation"}]}"#.into(),
            r#"{"ratings":[{"group_id":1,"importance":1,"confidence":0.9,"reason":"Routine product announcement"}]}"#.into(),
        ]);
        let result = plan(Some(&provider), "same-model", listing(2), 2)
            .await
            .unwrap();
        assert_eq!(result[0].members, vec![0]);
        assert_eq!(result[1].members, vec![1]);
        assert_eq!(result[0].importance, 5.0);
        assert_eq!(result[1].importance, 1.0);
        assert_eq!(result[1].reason, "Routine product announcement");
        let calls = provider.requests.lock().unwrap();
        assert_eq!(calls.len(), 4);
        assert!(calls
            .iter()
            .all(|r| r.model == "same-model" && r.temperature == Some(0.0)));
        assert_eq!(
            calls[2].messages[0].content,
            story_policy::semantic_rating_prompt()
        );
        let payload: serde_json::Value =
            serde_json::from_str(&calls[2].messages[1].content).unwrap();
        assert_eq!(payload["groups"].as_array().unwrap().len(), 1);
        assert!(payload["groups"][0].get("importance").is_none());
        assert_eq!(payload["groups"][0]["reports"][0]["index"], 0);
    }

    #[tokio::test]
    async fn two_pass_verification_splits_non_clique_and_preserves_reports() {
        let provider = Scripted::new(vec![
            first_pass(vec![2, 0, 1]),
            serde_json::json!([
                {"members":[0,1],"same_event":true,"confidence":1},
                {"members":[0,2],"same_event":false,"confidence":1},
                {"members":[1,2],"same_event":true,"confidence":1}
            ])
            .to_string(),
        ]);
        let result = plan(Some(&provider), "same-model", listing(3), 3)
            .await
            .unwrap();
        let mut memberships: Vec<_> = result
            .iter()
            .map(|group| {
                let mut members = group.members.clone();
                members.sort();
                members
            })
            .collect();
        memberships.sort();
        assert_eq!(memberships, vec![vec![0, 1], vec![2]]);
        assert!(result
            .iter()
            .all(|group| group.importance == 3.0 && group.reason == "From your feeds"));
        let calls = provider.requests.lock().unwrap();
        assert_eq!(calls.len(), 3);
        assert!(calls.iter().all(|request| request.model == "same-model"
            && request.temperature == Some(0.0)
            && request.json_mode
            && request.tools.is_none()));
        let pair_input: serde_json::Value =
            serde_json::from_str(&calls[1].messages[1].content).unwrap();
        assert_eq!(
            pair_input["pairs"],
            serde_json::json!([[0, 1], [0, 2], [1, 2]])
        );
        assert_eq!(pair_input["reports"].as_array().unwrap().len(), 3);
        assert_eq!(pair_input["reports"][0]["activity_date"], "2024-09-24");
        assert_eq!(pair_input["reports"][0].as_object().unwrap().len(), 4);
    }

    #[tokio::test]
    async fn failed_or_incomplete_ratings_keep_verified_groups_neutral() {
        let base = r#"{"ratings":[{"group_id":1,"importance":1,"confidence":0.9,"reason":"Routine announcement"}]}"#;
        let valid: serde_json::Value = serde_json::from_str(base).unwrap();
        let mut invalid = vec![
            "not JSON".into(),
            r#"{"ratings":[]}"#.into(),
            format!("Prose {base}"),
        ];
        for value in [
            serde_json::json!(0),
            serde_json::json!(2),
            serde_json::json!(0.5),
            serde_json::json!(true),
        ] {
            let mut bad = valid.clone();
            bad["ratings"][0]["group_id"] = value;
            invalid.push(bad.to_string());
        }
        for (key, value) in [
            ("importance", serde_json::json!(6)),
            ("confidence", serde_json::json!(0.79)),
            ("confidence", serde_json::json!(1.1)),
            ("reason", serde_json::json!(" ")),
            ("reason", serde_json::json!("x".repeat(281))),
        ] {
            let mut bad = valid.clone();
            bad["ratings"][0][key] = value;
            invalid.push(bad.to_string());
        }
        for response in invalid {
            let provider = Scripted::new(vec![
                first_pass(vec![0, 1]),
                r#"{"pairs":[{"members":[0,1],"same_event":false,"confidence":1}]}"#.into(),
                r#"{"ratings":[{"group_id":0,"importance":5,"confidence":0.95,"reason":"Urgent evacuation"}]}"#.into(),
                response,
            ]);
            let result = plan(Some(&provider), "fake", listing(2), 2).await.unwrap();
            assert_eq!(provider.requests.lock().unwrap().len(), 4);
            assert_eq!(
                result.iter().map(|g| g.members.clone()).collect::<Vec<_>>(),
                vec![vec![0], vec![1]]
            );
            assert!(result
                .iter()
                .all(|g| g.importance == 3.0 && g.reason == "From your feeds"));
        }
    }

    #[tokio::test]
    async fn rating_deadline_preserves_neutral_memberships_without_extending_total_budget() {
        let mut provider = Scripted::new(vec![
            first_pass(vec![0, 1]),
            r#"{"pairs":[{"members":[0,1],"same_event":false,"confidence":1}]}"#.into(),
            r#"{"ratings":[{"group_id":0,"importance":5,"confidence":1,"reason":"Urgent event"}]}"#
                .into(),
            "too late".into(),
        ]);
        provider.delay = Duration::from_millis(60);
        let result = plan_with_timeout(
            Some(&provider),
            "fake",
            listing(2),
            2,
            Duration::from_millis(220),
        )
        .await
        .unwrap();
        assert_eq!(provider.requests.lock().unwrap().len(), 4);
        assert_eq!(result.len(), 2);
        assert!(result.iter().all(|g| g.importance == 3.0));
    }

    #[tokio::test]
    async fn confirmed_group_needs_no_new_rating_call() {
        let provider = Scripted::new(vec![
            first_pass(vec![0, 1]),
            r#"{"pairs":[{"members":[0,1],"same_event":true,"confidence":1}]}"#.into(),
        ]);
        let result = plan(Some(&provider), "fake", listing(2), 2).await.unwrap();
        assert_eq!(provider.requests.lock().unwrap().len(), 2);
        assert_eq!(result[0].importance, 4.0);
        assert_eq!(result[0].reason, "Original event assertion");
    }

    #[tokio::test]
    async fn singleton_skips_verification_and_pair_budget_fails_closed() {
        let singleton = Scripted::new(vec![first_pass(vec![0])]);
        assert!(plan(Some(&singleton), "fake", listing(2), 2)
            .await
            .is_some());
        assert_eq!(singleton.requests.lock().unwrap().len(), 1);
        let oversized = Scripted::new(vec![first_pass((0..12).collect())]);
        assert!(plan(Some(&oversized), "fake", listing(12), 12)
            .await
            .is_none());
        assert_eq!(oversized.requests.lock().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn foreign_pair_response_discards_entire_primary_plan() {
        let provider = Scripted::new(vec![
            first_pass(vec![0, 1]),
            r#"{"pairs":[{"members":[0,2],"same_event":true,"confidence":1}]}"#.into(),
        ]);
        assert!(plan(Some(&provider), "fake", listing(3), 3).await.is_none());
        assert_eq!(provider.requests.lock().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn two_calls_share_one_deadline() {
        let mut provider = Scripted::new(vec![
            first_pass(vec![0, 1]),
            r#"{"pairs":[{"members":[0,1],"same_event":true,"confidence":1}]}"#.into(),
        ]);
        provider.delay = Duration::from_millis(60);
        assert!(plan_with_timeout(
            Some(&provider),
            "fake",
            listing(2),
            2,
            Duration::from_millis(100)
        )
        .await
        .is_none());
        assert_eq!(provider.requests.lock().unwrap().len(), 2);
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
        assert!(request(
            &FoundationBudget,
            "fake",
            story_policy::semantic_pair_prompt(),
            "界".repeat(1000)
        )
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
