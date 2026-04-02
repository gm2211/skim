use crate::db::models::AiSettings;

pub fn theme_grouping_system_prompt() -> &'static str {
    "You organize news articles into coherent thematic groups. \
     You write clearly and precisely. No filler, no hedging, no emoji. \
     Executive summaries should be dense with information - every sentence should convey something specific."
}

pub fn theme_grouping_user_prompt(articles_json: &str) -> String {
    format!(
        r#"Group these articles by theme. For each theme provide:
- A concise label (2-5 words)
- An executive summary (2-3 sentences covering key developments, be specific)
- Article IDs that belong to this theme
- Relevance score (0-1) for each article

Target 5-15 themes. Articles can appear in multiple themes if relevant.

Articles:
{articles_json}

Respond in this exact JSON format:
{{
  "themes": [
    {{
      "label": "string",
      "summary": "string",
      "articles": [
        {{"id": "string", "relevance": 0.9}}
      ]
    }}
  ]
}}"#
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
            let max_tokens = (words as i64) * 2; // ~2 tokens per word
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

pub fn triage_system_prompt(preferences: Option<&crate::db::models::UserPreferenceProfile>) -> String {
    let base = "You triage RSS articles for a busy reader. For each article, assign a priority (1-5) and write a one-line reason (under 80 chars) explaining why it matters or doesn't.\n\n\
     Priority scale:\n\
     5 = Breaking/urgent, directly relevant, actionable\n\
     4 = Important development, significant news\n\
     3 = Interesting, worth reading when time allows\n\
     2 = Routine update, low novelty\n\
     1 = Noise, promotional, or not useful\n\n\
     Be opinionated. Most articles should be 2-3. Reserve 5 for genuinely important items. Reserve 1 for clear noise.";

    match preferences {
        Some(prefs) if prefs.total_interactions >= 5 => {
            let mut context = String::from(base);
            context.push_str("\n\n--- Reader's learned preferences (use these to personalize priorities) ---\n");

            if !prefs.top_feeds.is_empty() {
                context.push_str(&format!("Preferred sources (boost priority slightly): {}\n", prefs.top_feeds.join(", ")));
            }
            if !prefs.preferred_topics.is_empty() {
                let sample: Vec<&str> = prefs.preferred_topics.iter().take(15).map(|s| s.as_str()).collect();
                context.push_str(&format!("Topics the reader engages with most (boost priority):\n{}\n", sample.join("\n")));
            }
            if !prefs.deprioritized_topics.is_empty() {
                let sample: Vec<&str> = prefs.deprioritized_topics.iter().take(10).map(|s| s.as_str()).collect();
                context.push_str(&format!("Topics the reader deprioritized (lower priority):\n{}\n", sample.join("\n")));
            }
            context
        }
        _ => base.to_string(),
    }
}

pub fn triage_user_prompt(articles_json: &str) -> String {
    format!(
        r#"Triage these articles. For each, return its id, a priority (1-5), and a reason (one sentence, under 80 chars).

Articles:
{articles_json}

Respond in this exact JSON format:
{{
  "triage": [
    {{"id": "article-id-here", "priority": 3, "reason": "Routine product update, nothing novel"}}
  ]
}}"#
    )
}

pub fn bullet_max_tokens(settings: &AiSettings) -> i64 {
    length_params(settings).2
}

pub fn full_max_tokens(settings: &AiSettings) -> i64 {
    length_params(settings).3
}
