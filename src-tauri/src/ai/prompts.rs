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

    let tone = match settings.summary_tone.as_deref().unwrap_or("concise") {
        "detailed" => "You provide thorough, detailed summaries that capture nuance and context.",
        "casual" => "You write in a casual, accessible tone. Keep it conversational and easy to read.",
        "technical" => "You write precise, technical summaries. Use domain-specific terminology where appropriate.",
        _ => "You write concisely and precisely. No filler, no hedging.",
    };

    format!(
        "{tone} Lead with the single most important takeaway. \
         Always respond with a JSON object containing exactly two string keys: \"summary\" and \"notes\". \
         Never use arrays, nested objects, or any other keys. Put your entire summary as a single string in \"summary\"."
    )
}

fn length_params(settings: &AiSettings) -> (String, String, i64, i64) {
    // Returns (bullet_count, paragraph_desc, bullet_max_tokens, full_max_tokens)
    if settings.summary_length.as_deref() == Some("custom") {
        if let Some(words) = settings.summary_custom_word_count {
            let bullets = std::cmp::max(2, words / 30);
            // The requested word count covers the prose, not the JSON keys,
            // punctuation and notes. Small custom summaries otherwise exhaust
            // their budget before the structured response can close.
            let max_tokens = (words as i64) * 2 + 128;
            return (
                format!("{}-{}", bullets, bullets + 2),
                format!("approximately {} words", words),
                max_tokens,
                max_tokens,
            );
        }
    }
    // max_tokens includes JSON overhead (~50 tokens for keys/braces)
    match settings.summary_length.as_deref().unwrap_or("short") {
        "short" => ("2-3".into(), "1-2 sentences (~30 words)".into(), 200, 256),
        "long" => ("5-8".into(), "3-5 paragraphs (~300 words)".into(), 1200, 2400),
        "medium" => ("3-5".into(), "2-3 paragraphs (~150 words)".into(), 600, 1200),
        _ => ("2-3".into(), "1-2 sentences (~30 words)".into(), 200, 256),
    }
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
Put your bullet points as a JSON array of strings in "bullets". Put any caveats in "notes".

Example of the expected output format:
{{"bullets": ["CERN scientists discovered the Zephyr boson in LHC collisions.", "The particle does not fit the Standard Model."], "notes": "Preliminary findings only."}}

Now write your JSON for the article above:"#
    )
}

pub fn article_full_summary_prompt(title: &str, text: &str, settings: &AiSettings) -> String {
    let truncated: String = text.chars().take(8000).collect();
    let (_, paragraph_count, _, _) = length_params(settings);

    match settings.summary_format.as_deref().unwrap_or("paragraph") {
        "bullets" => return String::new(), // skip full summary if bullets-only
        _ => {}
    }

    let example = match settings.summary_length.as_deref().unwrap_or("short") {
        "long" => r#"{"summary": "Scientists at CERN announced the discovery of a new subatomic particle called the Zephyr boson. The particle was detected during high-energy collisions in the Large Hadron Collider and has properties that challenge the Standard Model. If confirmed, this could open the door to new physics, potentially explaining dark matter and dark energy. The research team, led by Dr. Elena Vasquez, published their findings in Nature Physics. The discovery has generated significant excitement in the scientific community.", "notes": "none"}"#,
        "medium" => r#"{"summary": "Scientists at CERN discovered a new subatomic particle called the Zephyr boson that challenges the Standard Model. If confirmed by independent experiments, it could reshape quantum physics and help explain dark matter and dark energy.", "notes": "none"}"#,
        _ => r#"{"summary": "CERN scientists discovered the Zephyr boson, a particle that challenges the Standard Model.", "notes": "none"}"#,
    };

    format!(
        r#"Summarize the following article in {paragraph_count}.

Article title: {title}

Article text:
{truncated}

Respond with a JSON object with keys "summary" and "notes". Example:
{example}"#
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
    format!(
        "You write the lede that runs under a newspaper headline. Output JSON only.\n\n\
     {FRONT_PAGE_STANDARD}\n\n\
     The lede:\n\
     - 2-3 sentences, plain text, no markdown.\n\
     - The first sentence says what happened, concretely, using the specifics in the article text: names, numbers, versions, dates, who did it.\n\
     - A later sentence says why it matters to this reader, and only where that is genuinely not obvious from the first.\n\
     - Never restate the headline, never say \"the article discusses\" or \"this piece covers\", never hedge.\n\
     - Use only what the supplied text supports. Where it is thin, say the little that is known and stop. A short honest lede beats a padded one."
    )
}

/// Pass two's user turn, for one story.
pub fn catchup_lede_user_prompt(headline: &str, articles_text: &str) -> String {
    format!(
        r#"Headline: {headline}

Article text behind it:
{articles_text}

Output JSON:
{{"lede":"What happened, with the specifics. Why it matters."}}"#
    )
}
