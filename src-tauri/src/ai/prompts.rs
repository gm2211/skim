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

pub fn article_summary_system_prompt() -> &'static str {
    "You summarize articles precisely and concisely. \
     No filler, no hedging, no emoji. Every bullet point conveys a specific fact or insight. \
     Use clear, direct language."
}

pub fn article_bullet_summary_prompt(title: &str, text: &str) -> String {
    let truncated = if text.len() > 6000 {
        &text[..6000]
    } else {
        text
    };
    format!(
        r#"Summarize this article in 3-5 bullet points. Each bullet should be one clear sentence conveying a key fact or insight.

Title: {title}

Content:
{truncated}

Respond in this exact JSON format:
{{
  "bullets": ["string", "string", "string"]
}}"#
    )
}

pub fn article_full_summary_prompt(title: &str, text: &str) -> String {
    let truncated = if text.len() > 8000 {
        &text[..8000]
    } else {
        text
    };
    format!(
        r#"Write a comprehensive summary of this article in 2-3 paragraphs. Be specific and precise. Include key facts, figures, and conclusions.

Title: {title}

Content:
{truncated}"#
    )
}
