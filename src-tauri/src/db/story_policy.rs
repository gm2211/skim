//! Safe adapter to the policy source also compiled into the native iOS app.

#[repr(C)]
#[derive(Clone, Copy)]
struct Thresholds {
    duplicate: f64,
    coverage: f64,
    borderline: f64,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Deserialize, serde::Serialize)]
pub struct SummaryPlan {
    pub word_count: i32,
    pub bullet_min: i32,
    pub bullet_max: i32,
    pub bullet_max_tokens: i32,
    pub full_max_tokens: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct EvidenceSpan {
    byte_offset: usize,
    byte_length: usize,
    scalar_count: usize,
}

extern "C" {
    fn skim_chat_evidence_spans(source: *const u8, source_len: usize, query: *const u8,
        query_len: usize, max_scalars: usize, out: *mut EvidenceSpan, capacity: usize) -> usize;
    fn skim_chat_rank(title_terms: u32, url_terms: u32, source_terms: u32, body_terms: u32) -> i32;
    fn skim_summary_plan(length: *const std::os::raw::c_char, custom_words: i64) -> SummaryPlan;
    fn skim_summary_min_words() -> i32;
    fn skim_summary_max_words() -> i32;
    fn skim_summary_custom_words_valid(words: i64) -> i32;
    fn skim_summary_style_prompt(tone: *const std::os::raw::c_char) -> *const std::os::raw::c_char;
    fn skim_today_lede_excerpt_valid(source: *const u8, source_len: usize, excerpt: *const u8, excerpt_len: usize) -> i32;
    fn skim_today_lede_source_index(sources: *const u8, sources_len: usize,
        offsets: *const usize, source_count: usize, excerpt: *const u8, excerpt_len: usize) -> i32;
    fn skim_today_lede_evidence_version() -> i32;
    fn skim_today_lede_retry_prompt() -> *const std::os::raw::c_char;
    fn skim_today_lede_prompt() -> *const std::os::raw::c_char;
    fn skim_today_lede_max_articles() -> usize;
    fn skim_today_lede_text_characters() -> usize;
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
    fn skim_semantic_pair_verdict(text: *const u8, length: usize) -> i32;
    fn skim_semantic_evidence_characters() -> usize;
    fn skim_semantic_pair_output_tokens() -> usize;
    fn skim_semantic_pair_batch_length(pair_count: usize, offset: usize) -> usize;
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

/// Preserve original UTF-8 passages; the common selector owns ranking and budgets.
pub fn chat_evidence(source: &str, query: &str, max_scalars: usize) -> String {
    let mut spans = [EvidenceSpan::default(); 4];
    let count = unsafe { skim_chat_evidence_spans(source.as_ptr(), source.len(),
        query.as_ptr(), query.len(), max_scalars, spans.as_mut_ptr(), spans.len()) };
    if count > spans.len() { return String::new(); }
    let mut passages = Vec::new();
    let mut previous_end = 0;
    let mut used = 0usize;
    for span in &spans[..count] {
        let Some(end) = span.byte_offset.checked_add(span.byte_length) else { return String::new(); };
        let Some(passage) = source.get(span.byte_offset..end) else { return String::new(); };
        if span.byte_offset < previous_end || passage.is_empty() { return String::new(); }
        let actual_count = passage.chars().count();
        if actual_count != span.scalar_count { return String::new(); }
        let Some(next_used) = used.checked_add(actual_count).and_then(|n|
            n.checked_add(if passages.is_empty() { 0 } else { 3 })) else { return String::new(); };
        if next_used > max_scalars { return String::new(); }
        used = next_used;
        passages.push(passage);
        previous_end = end;
    }
    passages.join("\n…\n")
}

pub fn chat_rank(title_terms: u32, url_terms: u32, source_terms: u32, body_terms: u32) -> i32 {
    unsafe { skim_chat_rank(title_terms, url_terms, source_terms, body_terms) }
}

pub fn summary_plan(length: Option<&str>, custom_words: Option<i64>) -> SummaryPlan {
    let length = length.and_then(|value| std::ffi::CString::new(value).ok());
    let ptr = length.as_ref().map_or(std::ptr::null(), |value| value.as_ptr());
    unsafe { skim_summary_plan(ptr, custom_words.unwrap_or(0)) }
}

pub fn summary_word_bounds() -> (i32, i32) {
    unsafe { (skim_summary_min_words(), skim_summary_max_words()) }
}

pub fn summary_custom_words_valid(words: i64) -> bool {
    unsafe { skim_summary_custom_words_valid(words) != 0 }
}

pub fn summary_style_prompt(tone: Option<&str>) -> &'static str {
    // Embedded NUL is an invalid tone, not permission to truncate it into a
    // recognized one. The optional owned CString lives through this C call.
    let tone = tone.and_then(|tone| std::ffi::CString::new(tone).ok());
    let ptr = tone.as_ref().map_or(std::ptr::null(), |tone| tone.as_ptr());
    // C returns immutable, static NUL-terminated UTF-8 storage.
    unsafe { std::ffi::CStr::from_ptr(skim_summary_style_prompt(ptr)) }
        .to_str().expect("shared summary style is UTF-8")
}

pub fn today_lede_evidence_version() -> i32 {
    unsafe { skim_today_lede_evidence_version() }
}

pub fn validated_today_excerpt(source: &str, excerpt: &str) -> Option<String> {
    let excerpt = excerpt.split_whitespace().collect::<Vec<_>>().join(" ");
    // Owned UTF-8 buffers remain alive for the synchronous, read-only C call.
    let valid = unsafe { skim_today_lede_excerpt_valid(source.as_ptr(), source.len(), excerpt.as_ptr(), excerpt.len()) };
    (valid != 0).then_some(excerpt)
}

/// The shared matcher owns passage validation and deterministic source selection.
pub fn validated_today_excerpt_source(sources: &[String], excerpt: &str) -> Option<(usize, String)> {
    let excerpt = excerpt.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut bytes = Vec::new();
    let mut offsets = Vec::with_capacity(sources.len() + 1);
    offsets.push(0);
    for source in sources {
        bytes.extend_from_slice(source.as_bytes());
        offsets.push(bytes.len());
    }
    let index = unsafe {
        skim_today_lede_source_index(bytes.as_ptr(), bytes.len(), offsets.as_ptr(),
            sources.len(), excerpt.as_ptr(), excerpt.len())
    };
    (index >= 0 && (index as usize) < sources.len()).then_some((index as usize, excerpt))
}

pub fn today_lede_retry_prompt() -> &'static str {
    unsafe { std::ffi::CStr::from_ptr(skim_today_lede_retry_prompt()) }
        .to_str().expect("shared retry instructions are UTF-8")
}

pub fn today_lede_prompt() -> &'static str {
    // The common policy owns this static NUL-terminated UTF-8 string.
    unsafe { std::ffi::CStr::from_ptr(skim_today_lede_prompt()) }
        .to_str()
        .expect("shared lede instructions are UTF-8")
}

pub fn today_lede_max_articles() -> usize {
    unsafe { skim_today_lede_max_articles() }
}

pub fn today_lede_text_characters() -> usize {
    unsafe { skim_today_lede_text_characters() }
}

pub fn semantic_pair_prompt() -> &'static str {
    // Static NUL-terminated UTF-8 string owned by the common policy.
    unsafe { std::ffi::CStr::from_ptr(skim_semantic_pair_prompt()) }
        .to_str()
        .expect("shared pair prompt is UTF-8")
}

pub fn semantic_pair_batch_length(pair_count: usize, offset: usize) -> usize {
    unsafe { skim_semantic_pair_batch_length(pair_count, offset) }
}

pub fn semantic_pair_verdict(response: &str) -> i32 {
    unsafe { skim_semantic_pair_verdict(response.as_ptr(), response.len()) }
}
pub fn semantic_evidence_characters() -> usize { unsafe { skim_semantic_evidence_characters() } }
pub fn semantic_pair_output_tokens() -> usize { unsafe { skim_semantic_pair_output_tokens() } }

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
    fn shared_semantic_pair_batch_fixture() {
        let cases: serde_json::Value = serde_json::from_str(include_str!("../../../shared/fixtures/semantic-pair-batches.json")).unwrap();
        for case in cases.as_array().unwrap() {
            assert_eq!(super::semantic_pair_batch_length(case["pair_count"].as_u64().unwrap() as usize,
                case["offset"].as_u64().unwrap() as usize), case["length"].as_u64().unwrap() as usize, "{case}");
        }
    }

    #[test]
    fn shared_chat_evidence_fixture_preserves_facts_qualifiers_and_unicode() {
        #[derive(serde::Deserialize)]
        struct Segment { text: String, repeat: Option<usize> }
        #[derive(serde::Deserialize)]
        struct Case {
            name: String, segments: Vec<Segment>, query: String, max_scalars: usize,
            contains: Vec<String>, exact_source: Option<bool>, min_scalars: Option<usize>,
        }
        let cases: Vec<Case> = serde_json::from_str(include_str!("../../../shared/fixtures/chat-evidence.json")).unwrap();
        let mut failures = Vec::new();
        for case in cases {
            let source = case.segments.iter().map(|segment|
                segment.text.repeat(segment.repeat.unwrap_or(1))).collect::<String>();
            let actual = chat_evidence(&source, &case.query, case.max_scalars);
            let scalars = actual.chars().count();
            assert!(scalars <= case.max_scalars, "{} exceeds budget", case.name);
            if let Some(minimum) = case.min_scalars { assert!(scalars >= minimum, "{} produced only {scalars} scalars", case.name); }
            for expected in case.contains {
                if !actual.contains(&expected) {
                    failures.push(format!("{} missing {:?}; selected {:?}", case.name, expected, actual));
                }
            }
            if case.exact_source == Some(true) { assert_eq!(actual, source, "{}", case.name); }
            for passage in actual.split("\n…\n") {
                assert!(!passage.is_empty() && source.contains(passage), "{} rewrote source evidence", case.name);
            }
        }
        assert!(failures.is_empty(), "{}", failures.join("\n"));
    }

    #[test]
    fn chat_ranking_shared_fixture_and_coverage_dominance() {
        #[derive(serde::Deserialize)]
        struct Case { name: String, title_terms: u32, url_terms: u32, source_terms: u32, body_terms: u32, rank: i32 }
        let cases: Vec<Case> = serde_json::from_str(include_str!("../../../shared/fixtures/chat-ranking.json")).unwrap();
        for case in cases {
            assert_eq!(chat_rank(case.title_terms, case.url_terms, case.source_terms, case.body_terms), case.rank, "{}", case.name);
        }
        for covered in 0..32 {
            let partial = ((1u64 << covered) - 1) as u32;
            let complete = ((1u64 << (covered + 1)) - 1) as u32;
            assert!(chat_rank(0, 0, 0, complete) > chat_rank(partial, partial, partial, partial));
        }
    }

    #[test]
    fn shared_summary_plans_bound_invalid_counts_before_arithmetic() {
        #[derive(serde::Deserialize)]
        struct Case { length: Option<String>, custom_words: i64, valid_custom: bool, plan: SummaryPlan }
        let cases: Vec<Case> = serde_json::from_str(include_str!("../../../shared/fixtures/summary-plan.json")).unwrap();
        assert_eq!(summary_word_bounds(), (20, 1000));
        for case in cases {
            let plan = summary_plan(case.length.as_deref(), Some(case.custom_words));
            assert_eq!(plan, case.plan);
            assert_eq!(summary_custom_words_valid(case.custom_words), case.valid_custom);
            assert!((20..=1000).contains(&plan.word_count));
            assert!((1..=2400).contains(&plan.full_max_tokens));
            assert!((1..=2400).contains(&plan.bullet_max_tokens));
        }
        assert_eq!(summary_plan(Some("custom"), None), summary_plan(None, None));
        assert_eq!(summary_plan(Some("custom\0long"), Some(1000)), summary_plan(None, None));
    }

    #[test]
    fn summary_style_shared_fixture_crosses_rust_abi() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../shared/fixtures/summary-style.json")).unwrap();
        for case in fixture["cases"].as_array().unwrap() {
            assert_eq!(summary_style_prompt(case["tone"].as_str()),
                format!("{} {}", case["style"].as_str().unwrap(), fixture["common"].as_str().unwrap()),
                "tone: {:?}", case["tone"]);
        }
    }

    #[test]
    fn preview_source_identity_crosses_shared_c_fixture() {
        let cases: serde_json::Value = serde_json::from_str(include_str!("../../../shared/fixtures/today-excerpt-sources.json")).unwrap();
        for case in cases.as_array().unwrap() {
            let sources: Vec<String> = case["sources"].as_array().unwrap().iter().map(|v| v.as_str().unwrap().to_owned()).collect();
            let result = validated_today_excerpt_source(&sources, case["excerpt"].as_str().unwrap());
            assert_eq!(result.map_or(-1, |(index, _)| index as i64), case["index"].as_i64().unwrap(), "{case}");
        }
    }

    #[test]
    fn verified_today_excerpts_match_shared_corpus() {
        let cases: serde_json::Value = serde_json::from_str(include_str!("../../../shared/fixtures/today-excerpts.json")).unwrap();
        for case in cases.as_array().unwrap() {
            let result = validated_today_excerpt(case["source"].as_str().unwrap(), case["excerpt"].as_str().unwrap());
            assert_eq!(result.is_some(), case["valid"].as_bool().unwrap(), "{case}");
            if let Some(result) = result { assert_eq!(result, case["excerpt"].as_str().unwrap().split_whitespace().collect::<Vec<_>>().join(" ")); }
        }
    }

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
