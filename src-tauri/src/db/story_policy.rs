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

#[cfg(test)]
mod tests {
    use super::*;

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
