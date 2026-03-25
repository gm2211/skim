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
        "{tone} Every point conveys a specific fact or insight. Use clear, direct language. No emoji. \
         Lead with the single most important takeaway — the one sentence someone should remember if they read nothing else."
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
    match settings.summary_length.as_deref().unwrap_or("short") {
        "short" => ("2-3".into(), "1-2 sentences (~30 words)".into(), 128, 192),
        "long" => ("5-8".into(), "3-5 paragraphs (~300 words)".into(), 1024, 2048),
        "medium" => ("3-5".into(), "2-3 paragraphs (~150 words)".into(), 512, 1024),
        _ => ("2-3".into(), "1-2 sentences (~30 words)".into(), 128, 192),
    }
}

pub fn article_bullet_summary_prompt(title: &str, text: &str, settings: &AiSettings) -> String {
    let truncated: String = text.chars().take(6000).collect();
    let (bullet_count, _, _, _) = length_params(settings);

    if settings.summary_format.as_deref().unwrap_or("paragraph") == "paragraph" {
        return String::new(); // skip bullets if paragraph-only
    }

    format!(
        r#"Summarize this article in {bullet_count} bullet points. Each bullet should be one clear sentence conveying a key fact or insight.

Title: {title}

Content:
{truncated}

CRITICAL: Respond with ONLY a valid JSON object. No text, explanation, or thinking before or after the JSON.
If you need to reason about the article, put ALL reasoning in the "notes" field — NEVER in "bullets".
The "bullets" field must contain ONLY the final bullet point strings.

{{
  "bullets": ["First key point", "Second key point", "Third key point"],
  "notes": "Put any reasoning, thinking process, analysis, caveats, or meta-commentary here."
}}"#
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
        r#"Summarize this article in {paragraph_count}. Be specific and precise. Include key facts, figures, and conclusions.

Title: {title}

Content:
{truncated}

CRITICAL: Respond with ONLY a valid JSON object. No text, explanation, or thinking before or after the JSON.
If you need to reason about the article, put ALL reasoning in the "notes" field — NEVER in "summary".
The "summary" field must contain ONLY the final summary text.

{{
  "summary": "The actual summary text only. No reasoning, no analysis, no thinking process.",
  "notes": "Put any reasoning, thinking process, analysis, caveats, or meta-commentary here."
}}"#
    )
}

pub fn bullet_max_tokens(settings: &AiSettings) -> i64 {
    length_params(settings).2
}

pub fn full_max_tokens(settings: &AiSettings) -> i64 {
    length_params(settings).3
}
