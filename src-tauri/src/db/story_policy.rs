//! Safe adapter to the policy source also compiled into the native iOS app.

#[repr(C)]
#[derive(Clone, Copy)]
struct Thresholds {
    duplicate: f64,
    coverage: f64,
    borderline: f64,
}

extern "C" {
    fn skim_story_default_thresholds() -> Thresholds;
    fn skim_story_confidence(lexical_similarity: f64, title_similarity: f64) -> f64;
    fn skim_story_classify(
        confidence: f64,
        title_similarity: f64,
        entity_guard: i32,
        is_update: i32,
        thresholds: Thresholds,
    ) -> i32;
    fn skim_story_score(sources: i64, age: f64, window: f64, preference: f64) -> f64;
    fn skim_story_is_unique(sources: i64) -> i32;
    fn skim_story_identity_hash(bytes: *const u8, length: usize) -> u64;
    fn skim_semantic_pair_prompt() -> *const std::os::raw::c_char;
    fn skim_semantic_rating_prompt() -> *const std::os::raw::c_char;
    fn skim_semantic_rating_valid(importance: f64, confidence: f64) -> i32;
    fn skim_semantic_max_pairs() -> usize;
    fn skim_semantic_partition(
        members: *const f64,
        member_count: usize,
        candidate_count: usize,
        verified: *const u8,
        verified_count: usize,
        labels: *mut i32,
        labels_count: usize,
    ) -> i32;
    fn skim_semantic_prompt() -> *const std::os::raw::c_char;
    fn skim_semantic_max_candidates() -> usize;
    fn skim_semantic_group_valid(
        members: *const f64,
        member_count: usize,
        candidate_count: usize,
        assigned: *const u8,
        assigned_count: usize,
        importance: f64,
        confidence: f64,
    ) -> i32;
    fn skim_semantic_score(base: f64, importance: f64, confidence: f64) -> f64;
}

#[derive(Debug, PartialEq)]
pub enum Relationship {
    Separate,
    Duplicate,
    Coverage,
    Update,
    Borderline,
}

pub fn confidence(lexical: f64, title: f64) -> f64 {
    // All scalar calls use the fixed C ABI declared in SkimStoryPolicy.h.
    unsafe { skim_story_confidence(lexical, title) }
}

pub fn classify(confidence: f64, title: f64, entity_guard: bool, is_update: bool) -> Relationship {
    let kind = unsafe {
        skim_story_classify(
            confidence,
            title,
            i32::from(entity_guard),
            i32::from(is_update),
            skim_story_default_thresholds(),
        )
    };
    match kind {
        1 => Relationship::Duplicate,
        2 => Relationship::Coverage,
        3 => Relationship::Update,
        4 => Relationship::Borderline,
        _ => Relationship::Separate,
    }
}

pub fn score(sources: i64, age: f64, window: f64, preference: f64) -> f64 {
    unsafe { skim_story_score(sources, age, window, preference) }
}

pub fn is_unique(sources: i64) -> bool {
    unsafe { skim_story_is_unique(sources) != 0 }
}

pub fn identity_hash(seed: &str) -> u64 {
    // C reads exactly this slice synchronously and never retains its pointer.
    unsafe { skim_story_identity_hash(seed.as_ptr(), seed.len()) }
}

pub fn semantic_pair_prompt() -> &'static str {
    // Static NUL-terminated UTF-8 string owned by the common policy.
    unsafe { std::ffi::CStr::from_ptr(skim_semantic_pair_prompt()) }
        .to_str()
        .expect("shared pair prompt is UTF-8")
}

pub fn semantic_max_pairs() -> usize {
    unsafe { skim_semantic_max_pairs() }
}

pub fn semantic_rating_prompt() -> &'static str {
    // Static string owned by the shared C policy.
    unsafe { std::ffi::CStr::from_ptr(skim_semantic_rating_prompt()) }
        .to_str()
        .expect("shared rating prompt is UTF-8")
}

pub fn valid_semantic_rating(importance: f64, confidence: f64) -> bool {
    unsafe { skim_semantic_rating_valid(importance, confidence) != 0 }
}

pub fn semantic_partition(
    members: &[usize],
    candidate_count: usize,
    verified: &[u8],
) -> Option<Vec<Vec<usize>>> {
    let numeric: Vec<f64> = members.iter().map(|&index| index as f64).collect();
    let mut labels = vec![-1; members.len()];
    // C receives actual slice lengths; all buffers live for the synchronous call.
    let count = unsafe {
        skim_semantic_partition(
            numeric.as_ptr(),
            numeric.len(),
            candidate_count,
            verified.as_ptr(),
            verified.len(),
            labels.as_mut_ptr(),
            labels.len(),
        )
    };
    if count <= 0 || count as usize > members.len() {
        return None;
    }
    let mut groups = vec![Vec::new(); count as usize];
    for (&member, label) in members.iter().zip(labels) {
        groups.get_mut(usize::try_from(label).ok()?)?.push(member);
    }
    if groups.iter().any(Vec::is_empty) {
        return None;
    }
    Some(groups)
}

pub fn semantic_prompt() -> &'static str {
    // C returns a static, NUL-terminated UTF-8 string; ownership never transfers.
    unsafe { std::ffi::CStr::from_ptr(skim_semantic_prompt()) }
        .to_str()
        .expect("shared semantic prompt is UTF-8")
}

pub fn semantic_max_candidates() -> usize {
    unsafe { skim_semantic_max_candidates() }
}

pub fn valid_semantic_group(
    members: &[f64],
    candidate_count: usize,
    assigned: &[u8],
    importance: f64,
    confidence: f64,
) -> bool {
    // Both borrowed buffers remain alive for this synchronous, read-only call.
    unsafe {
        skim_semantic_group_valid(
            members.as_ptr(),
            members.len(),
            candidate_count,
            assigned.as_ptr(),
            assigned.len(),
            importance,
            confidence,
        ) != 0
    }
}

pub fn semantic_score(base: f64, importance: f64, confidence: f64) -> f64 {
    unsafe { skim_semantic_score(base, importance, confidence) }
}

#[cfg(test)]
mod tests {
    #[test]
    fn shared_pair_partition_fixture() {
        let cases: serde_json::Value =
            serde_json::from_str(include_str!("../../../shared/fixtures/semantic-pairs.json"))
                .unwrap();
        for case in cases.as_array().unwrap() {
            let count = case["candidate_count"].as_u64().unwrap() as usize;
            let members: Vec<usize> = serde_json::from_value(case["members"].clone()).unwrap();
            let mut matrix = vec![0u8; count * count];
            for pair in case["positive_pairs"].as_array().unwrap() {
                let a = pair[0].as_u64().unwrap() as usize;
                let b = pair[1].as_u64().unwrap() as usize;
                matrix[a * count + b] = 1;
                matrix[b * count + a] = 1;
            }
            let groups = super::semantic_partition(&members, count, &matrix).unwrap();
            let labels: Vec<usize> = members
                .iter()
                .map(|member| {
                    groups
                        .iter()
                        .position(|group| group.contains(member))
                        .unwrap()
                })
                .collect();
            assert_eq!(
                serde_json::json!(labels),
                case["expected_labels"],
                "{}",
                case["name"]
            );
        }
        assert!(super::semantic_partition(&[0, 1], 2, &[1]).is_none());
        assert!(super::semantic_partition(&[0, 0], 2, &[0; 4]).is_none());
    }

    use super::*;

    #[test]
    fn semantic_contract_rejects_invalid_groups_without_losing_handles() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../shared/fixtures/semantic-policy.json"
        ))
        .unwrap();
        for case in fixture.as_array().unwrap() {
            let members: Vec<f64> = case["members"]
                .as_array()
                .unwrap()
                .iter()
                .map(|n| n.as_f64().unwrap())
                .collect();
            let assigned: Vec<u8> = case["assigned"]
                .as_array()
                .unwrap()
                .iter()
                .map(|n| n.as_u64().unwrap() as u8)
                .collect();
            let importance = case["importance"].as_f64().unwrap();
            let confidence = case["confidence"].as_f64().unwrap();
            assert_eq!(
                valid_semantic_group(
                    &members,
                    case["count"].as_u64().unwrap() as usize,
                    &assigned,
                    importance,
                    confidence
                ),
                case["valid"].as_bool().unwrap(),
                "{}",
                case["name"]
            );
            assert_eq!(
                semantic_score(case["base"].as_f64().unwrap(), importance, confidence),
                case["score"].as_f64().unwrap(),
                "{}",
                case["name"]
            );
        }
        for invalid in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            assert!(!valid_semantic_group(&[invalid], 1, &[0], 3., 0.9));
            assert!(!valid_semantic_group(&[0.], 1, &[0], invalid, 0.9));
            assert!(!valid_semantic_group(&[0.], 1, &[0], 3., invalid));
        }
        assert!(!valid_semantic_group(
            &[0.],
            semantic_max_candidates() + 1,
            &vec![0; semantic_max_candidates() + 1],
            3.,
            0.9
        ));
    }

    #[test]
    fn shared_policy_contract_crosses_rust_abi() {
        let fixture: serde_json::Value =
            serde_json::from_str(include_str!("../../../shared/fixtures/story-policy.json"))
                .unwrap();
        for case in fixture["matches"].as_array().unwrap() {
            let expected = match case["kind"].as_i64().unwrap() {
                1 => Relationship::Duplicate,
                2 => Relationship::Coverage,
                3 => Relationship::Update,
                4 => Relationship::Borderline,
                _ => Relationship::Separate,
            };
            let title = case["title"].as_f64().unwrap();
            assert_eq!(
                classify(
                    confidence(case["lexical"].as_f64().unwrap(), title),
                    title,
                    case["entities"].as_bool().unwrap(),
                    case["update"].as_bool().unwrap()
                ),
                expected,
                "{}",
                case["name"]
            );
        }
        for case in fixture["ranks"].as_array().unwrap() {
            let sources = case["sources"].as_i64().unwrap();
            let actual = score(
                sources,
                case["age"].as_f64().unwrap(),
                case["window"].as_f64().unwrap(),
                case["preference"].as_f64().unwrap(),
            );
            assert!(
                (actual - case["score"].as_f64().unwrap()).abs() < 1e-12,
                "{}",
                case["name"]
            );
            assert_eq!(is_unique(sources), case["unique"].as_bool().unwrap());
        }
    }
}
