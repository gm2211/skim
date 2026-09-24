use crate::db::models::AiSettings;

pub fn theme_grouping_system_prompt(user_prompt: Option<&str>) -> String {
    let base = "You group news articles into themes. Output JSON only. No filler, no hedging. \
     Labels: 2-5 words. Summaries: 1-2 dense sentences. \
     Refer to articles by their numeric handle.";
    match user_prompt {
        Some(p) if !p.trim().is_empty() => {
            format!(
                "{base}\n\n--- Reader's interests (explicit) ---\n{}\n\
                 Use this as a gentle nudge when labeling/grouping themes. Labels must still describe the articles themselves.",
                p.trim()
            )
        }
        _ => base.to_string(),
    }
}

pub fn theme_grouping_user_prompt(articles_listing: &str) -> String {
    format!(
        r#"Articles (handle TAB title TAB [source]):
{articles_listing}
Target 4-10 themes. Each article in 1-2 themes max.

Output JSON:
{{"themes":[{{"label":"Name","summary":"Dense summary.","articles":[{{"id":0,"relevance":0.9}}]}}]}}"#
    )
}

pub fn article_summary_system_prompt(settings: &AiSettings) -> String {
    if let Some(ref custom) = settings.summary_custom_prompt {
        if !custom.trim().is_empty() {
            return custom.clone();
        }
    }

    let style = crate::db::story_policy::summary_style_prompt(settings.summary_tone.as_deref());

    format!(
        "{style} \
         Always respond with a JSON object using exactly the keys and value types requested in the user message. \
         Do not add other keys or text outside the JSON object."
    )
}

fn length_params(settings: &AiSettings) -> (String, String, i64, i64) {
    let plan = crate::db::story_policy::summary_plan(
        settings.summary_length.as_deref(), settings.summary_custom_word_count.map(i64::from));
    let description = match settings.summary_length.as_deref() {
        Some("custom") if settings.summary_custom_word_count.is_some_and(|words|
            crate::db::story_policy::summary_custom_words_valid(i64::from(words))) =>
            format!("approximately {} words", plan.word_count),
        Some("medium") => format!("2-3 paragraphs (~{} words)", plan.word_count),
        Some("long") => format!("3-5 paragraphs (~{} words)", plan.word_count),
        _ => format!("1-2 sentences (~{} words)", plan.word_count),
    };
    (format!("{}-{}", plan.bullet_min, plan.bullet_max), description,
        i64::from(plan.bullet_max_tokens), i64::from(plan.full_max_tokens))
}

pub fn article_bullet_summary_prompt(title: &str, text: &str, settings: &AiSettings) -> String {
    let truncated: String = text.chars().take(6000).collect();
    let (bullet_count, _, _, _) = length_params(settings);

    if settings.summary_format.as_deref().unwrap_or("paragraph") == "paragraph" {
        return String::new(); // skip bullets if paragraph-only
    }

    format!(
        r#"Summarize the following article in {bullet_count} bullet points. Each bullet is one clear sentence.

Article title: {title}

Article text:
{truncated}

Write a JSON object with exactly two keys: "bullets" and "notes".
Put your bullet points as a JSON array of strings in "bullets".
Put any caveats as a string in "notes"; use an empty string if none.
Do not add other keys or text outside the JSON object."#
    )
}

pub fn article_full_summary_prompt(title: &str, text: &str, settings: &AiSettings) -> String {
    let truncated: String = text.chars().take(8000).collect();
    let (_, paragraph_count, _, _) = length_params(settings);

    match settings.summary_format.as_deref().unwrap_or("paragraph") {
        "bullets" => return String::new(), // skip full summary if bullets-only
        _ => {}
    }

    format!(
        r#"Summarize the following article in {paragraph_count}.

Article title: {title}

Article text:
{truncated}

Respond with a JSON object containing exactly two string-valued keys: "summary" and "notes".
Put the entire summary in "summary". Put any caveats in "notes"; use an empty string if none.
Do not use arrays or add other keys or text outside the JSON object."#
    )
}

pub fn triage_system_prompt(
    preferences: Option<&crate::db::models::UserPreferenceProfile>,
    user_prompt: Option<&str>,
) -> String {
    let base = "You triage RSS articles for a busy reader. For each article, assign a priority (1-5) and write a one-line reason (under 80 chars) describing what the article is about and why it matters (or why it's noise).\n\n\
     Priority scale:\n\
     5 = Breaking/urgent, directly relevant, actionable\n\
     4 = Important development, significant news\n\
     3 = Interesting, worth reading when time allows\n\
     2 = Routine update, low novelty\n\
     1 = Noise, promotional, or not useful\n\n\
     Be opinionated. Most articles should be 2-3. Reserve 5 for genuinely important items. Reserve 1 for clear noise.\n\
     The reason field must describe the article itself — never mention \"tracked topics\", \"user preferences\", \"reader history\", or the reader's past behavior. The reader doesn't see or manage a topic list and will be confused by such phrasing.";

    let mut context = String::from(base);

    // Explicit user-authored prompt comes first — it's the strongest signal
    // because the reader wrote it themselves.
    if let Some(p) = user_prompt {
        let trimmed = p.trim();
        if !trimmed.is_empty() {
            context.push_str("\n\n--- Reader's interests (explicit) ---\n");
            context.push_str(trimmed);
            context.push('\n');
        }
    }

    // Only inject learned preferences after the reader has meaningfully
    // engaged with articles. Below 20 interactions the signal is too noisy
    // and produces hallucinated "tracked topic" reasons.
    if let Some(prefs) = preferences {
        if prefs.total_interactions >= 20 {
            context.push_str("\n--- Reader's learned preferences ---\n");
            context.push_str("(soft personalization hints — use as a gentle nudge, not a justification)\n");

            if !prefs.top_feeds.is_empty() {
                context.push_str(&format!("Sources the reader tends to open: {}\n", prefs.top_feeds.join(", ")));
            }
            if !prefs.preferred_topics.is_empty() {
                let sample: Vec<&str> = prefs.preferred_topics.iter().take(15).map(|s| s.as_str()).collect();
                context.push_str(&format!("Sample titles the reader spent time on (inspiration only, do not cite):\n{}\n", sample.join("\n")));
            }
            if !prefs.deprioritized_topics.is_empty() {
                let sample: Vec<&str> = prefs.deprioritized_topics.iter().take(10).map(|s| s.as_str()).collect();
                context.push_str(&format!("Sample titles the reader deprioritized (inspiration only, do not cite):\n{}\n", sample.join("\n")));
            }
            context.push_str("Reasons must still describe only the article itself.\n");
        }
    }

    context
}

pub fn triage_user_prompt(articles_listing: &str) -> String {
    format!(
        r#"Articles (handle TAB title TAB [source] TAB excerpt):
{articles_listing}
For EVERY article above, return an entry. Refer to articles by their numeric handle.

Output JSON:
{{"triage":[{{"id":0,"priority":3,"reason":"short reason"}}]}}"#
    )
}

pub fn bullet_max_tokens(settings: &AiSettings) -> i64 {
    length_params(settings).2
}

pub fn full_max_tokens(settings: &AiSettings) -> i64 {
    length_params(settings).3
}

// --- Quick Catch-up: the front page -----------------------------------------
//
// The old catch-up asked one model call for "the 10 most important takeaways,
// one tight sentence each" over titles and 220-character excerpts. That shape
// can only produce category labels ("Self-hosted analytics become more
// accessible."), so the page read as a bag of headlines with nothing under
// them. It now runs in two passes: pick and group the stories, then read the
// articles behind each one and write its lede.

/// Rules shared by both passes: what counts as a story, and what a headline
/// and a lede are allowed to be.
const FRONT_PAGE_STANDARD: &str = "A story is something that happened. \"ByteDance open-sourced its RL training stack\" is a story. \"Open-source RL gains traction\" is not — it is a category. If you cannot say what happened, there is no story.\n\n\
     Headlines:\n\
     - 4-10 words, present tense, naming the specific actor, product, project, company or number involved.\n\
     - Never a trend statement (\"... gains traction\", \"... are improving\", \"... are emerging\", \"... becomes more accessible\").\n\
     - Never a description of a source or its readership (\"Hacker News is active and diverse\").\n\
     - Never the name of a feed or a subject area on its own.";

/// Pass one: choose the stories, group the articles under them, and write the
/// short items that run below the fold.
pub fn catchup_page_system_prompt(user_prompt: Option<&str>) -> String {
    let base = format!(
        "You are the editor of a one-page newspaper built from a reader's RSS feed. Output JSON only.\n\n\
     Choose what goes on the front page and write each story's headline. Another pass writes the ledes, so you write no summaries here.\n\n\
     {FRONT_PAGE_STANDARD}\n\n\
     Grouping:\n\
     - Group articles only when they cover the same event or the same running story. Never group by source, by feed, or by broad subject area.\n\
     - Every article belongs to at most one story or one brief. Nothing appears twice on the page.\n\
     - Order the stories so the most consequential comes first.\n\n\
     Picking:\n\
     - Aim for 4-6 stories, and prefer fewer real ones over more filler. If only two things actually happened, return two stories.\n\
     - Anything else worth a glance goes in \"briefs\": one concrete sentence saying what happened, at most 6 of them. A brief that does not say what happened does not belong on the page.\n\
     - Leave out items with nothing to report. An empty briefs list is a perfectly good answer."
    );

    match user_prompt {
        Some(p) if !p.trim().is_empty() => format!(
            "{base}\n\n--- Reader's interests (explicit) ---\n{}\n\
             Let this nudge which stories lead the page. It never relaxes the rules above: headlines still say what happened.",
            p.trim()
        ),
        _ => base,
    }
}

/// Pass one's user turn.
pub fn catchup_page_user_prompt(articles_listing: &str) -> String {
    format!(
        r#"Articles (handle TAB title TAB [publication] TAB excerpt):
{articles_listing}
Refer to articles by their numeric handle.

Output JSON:
{{"stories":[{{"headline":"Actor does specific thing","article_ids":[0,3]}}],"briefs":[{{"text":"One concrete sentence about what happened.","article_ids":[5]}}]}}"#
    )
}

/// Pass two: write the lede under one headline, from the full text of the
/// articles behind it.
pub fn catchup_lede_system_prompt() -> String {
    format!("{}\n\nOutput JSON with one string field named excerpt.", crate::db::story_policy::today_lede_prompt())
}

/// Pass two's user turn, for one story.
pub fn catchup_lede_user_prompt(headline: &str, articles_text: &str) -> String {
    format!(
        r#"Headline: {headline}

Article text behind it:
{articles_text}

Output JSON:
{{"excerpt":"A complete verbatim passage from one supplied report."}}"#
    )
}

/// Retry uses the same evidence without a JSON footer.
pub fn catchup_lede_retry_user_prompt(headline: &str, articles_text: &str) -> String {
    format!("Headline: {headline}\n\nArticle text behind it:\n{articles_text}")
}

#[cfg(test)]
mod summary_prompt_tests {
    use super::*;

    #[test]
    fn persisted_invalid_custom_counts_generate_short_safe_requests() {
        let mut settings = crate::db::models::AppSettings::default().ai;
        settings.summary_length = Some("custom".into());
        settings.summary_format = Some("both".into());
        for count in [None, Some(i32::MIN), Some(-100), Some(0), Some(19), Some(1001), Some(i32::MAX)] {
            settings.summary_custom_word_count = count;
            assert!(article_full_summary_prompt("Title", "Evidence", &settings).contains("1-2 sentences (~30 words)"));
            assert!(article_bullet_summary_prompt("Title", "Evidence", &settings).contains("2-3 bullet points"));
            assert_eq!(full_max_tokens(&settings), 256);
            assert_eq!(bullet_max_tokens(&settings), 200);
        }
    }

    #[test]
    fn every_summary_tone_uses_shared_fidelity_policy_before_json_adapter() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../shared/fixtures/summary-style.json")).unwrap();
        for case in fixture["cases"].as_array().unwrap() {
            let mut settings = crate::db::models::AppSettings::default().ai;
            settings.summary_tone = case["tone"].as_str().map(str::to_string);
            let prompt = article_summary_system_prompt(&settings);
            let expected = format!("{} {}", case["style"].as_str().unwrap(),
                fixture["common"].as_str().unwrap());
            assert!(prompt.starts_with(&expected));
            assert!(prompt.contains("keys and value types requested in the user message"));
            assert!(!prompt.contains("no hedging"));
        }
    }

    #[test]
    fn paragraph_bullet_and_both_requests_have_compatible_shapes() {
        for (format, bullets, prose) in [("paragraph", false, true), ("bullets", true, false), ("both", true, true)] {
            let mut settings = crate::db::models::AppSettings::default().ai;
            settings.summary_format = Some(format.into());
            let system = article_summary_system_prompt(&settings);
            assert!(system.contains("keys and value types requested in the user message"));
            assert!(!system.contains("Never use arrays"));
            let bullet = article_bullet_summary_prompt("Title", "Evidence", &settings);
            let full = article_full_summary_prompt("Title", "Evidence", &settings);
            assert_eq!(!bullet.is_empty(), bullets);
            assert_eq!(!full.is_empty(), prose);
            if bullets {
                assert!(bullet.contains("JSON array of strings in \"bullets\""));
                assert!(bullet.contains("as a string in \"notes\""));
            }
            if prose { assert!(full.contains("two string-valued keys: \"summary\" and \"notes\"")); }
        }
    }

    #[test]
    fn detail_levels_keep_counts_without_invented_example_facts() {
        for (length, words, bullets, full_tokens) in [
            ("short", "~30 words", "2-3", 256),
            ("medium", "~150 words", "3-5", 1200),
            ("long", "~300 words", "5-8", 2400),
            ("custom", "approximately 87 words", "2-4", 302),
        ] {
            let mut settings = crate::db::models::AppSettings::default().ai;
            settings.summary_format = Some("both".into());
            settings.summary_length = Some(length.into());
            settings.summary_custom_word_count = Some(87);
            let full = article_full_summary_prompt("Actual headline", "Actual source.", &settings);
            let bullet = article_bullet_summary_prompt("Actual headline", "Actual source.", &settings);
            assert!(full.contains(words));
            assert!(bullet.contains(&format!("in {bullets} bullet points")));
            assert_eq!(full_max_tokens(&settings), full_tokens);
            for prompt in [full, bullet] {
                assert!(prompt.contains("Actual source."));
                for invented in ["Zephyr", "CERN", "Elena", "dark matter", "Example"] {
                    assert!(!prompt.contains(invented));
                }
            }
        }
    }

    #[test]
    fn custom_system_prompt_and_tone_remain_intact() {
        let mut settings = crate::db::models::AppSettings::default().ai;
        settings.summary_tone = Some("technical".into());
        assert!(article_summary_system_prompt(&settings).starts_with("You write precise, technical summaries."));
        settings.summary_custom_prompt = Some(" My exact custom instructions. ".into());
        assert_eq!(article_summary_system_prompt(&settings), " My exact custom instructions. ");
        settings.summary_custom_prompt = Some("  ".into());
        assert!(article_summary_system_prompt(&settings).starts_with("You write precise, technical summaries."));
    }
}
