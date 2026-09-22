//! Turning an article's raw body into something printable under a headline.
//!
//! Story summaries used to be `content_text` truncated at 280 characters,
//! which is why a link-only Hacker News post rendered on the Today page as
//! `[Comments][1]  [1]: https://news.ycombinator.com/item?id=…`. Feeds carry
//! markdown, HTML and bare URLs in their bodies; none of it belongs on a
//! front page.

/// Longest printable summary, before the cut falls back to a word boundary.
const MAX_LEN: usize = 280;
/// Below this, a "sentence" is an artifact of an abbreviation, not a sentence.
const MIN_SENTENCE_LEN: usize = 60;

/// A clean one-or-two-sentence excerpt, or an empty string when the body holds
/// nothing worth printing. Callers fall back to the headline on empty.
pub fn excerpt(raw: &str) -> String {
    let text = collapse_whitespace(&strip_markup(raw));
    if text.is_empty() || is_bare_url(&text) {
        return String::new();
    }
    truncate_at_sentence(&text)
}

fn strip_markup(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut in_code_fence = false;

    for line in raw.lines() {
        let trimmed = line.trim();

        if trimmed.starts_with("```") || trimmed.starts_with("~~~") {
            in_code_fence = !in_code_fence;
            continue;
        }
        if in_code_fence {
            continue;
        }
        // A markdown link reference definition: `[1]: https://example.com`.
        if is_link_definition(trimmed) {
            continue;
        }

        out.push_str(&strip_line_markers(trimmed));
        out.push(' ');
    }

    let out = strip_links(&out);
    let out = strip_html(&out);
    let out = decode_entities(&out);
    strip_bare_urls(&out)
}

fn is_link_definition(line: &str) -> bool {
    let Some(rest) = line.strip_prefix('[') else {
        return false;
    };
    let Some(close) = rest.find("]:") else {
        return false;
    };
    // `[` … `]:` with a target after it, and no spaces inside the label that
    // would make this ordinary prose ending in a colon.
    !rest[..close].contains(']') && !rest[close + 2..].trim().is_empty()
}

/// Leading blockquote, heading, list and rule markers.
fn strip_line_markers(line: &str) -> String {
    let mut rest = line;
    loop {
        let trimmed = rest
            .trim_start_matches(['>', '#'])
            .trim_start();
        let trimmed = match trimmed.strip_prefix("- ") {
            Some(after) => after,
            None => match trimmed.strip_prefix("* ") {
                Some(after) => after,
                None => trimmed,
            },
        };
        if trimmed == rest {
            break;
        }
        rest = trimmed;
    }
    if rest.chars().all(|c| c == '-' || c == '*' || c == '_') {
        return String::new();
    }
    rest.to_string()
}

/// `![alt](url)` disappears; `[text](url)` and `[text][ref]` keep their text.
fn strip_links(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;

    while i < chars.len() {
        if chars[i] == '!' && chars.get(i + 1) == Some(&'[') {
            if let Some((_, after)) = link_parts(&chars, i + 1) {
                i = after;
                continue;
            }
        }
        if chars[i] == '[' {
            if let Some((label, after)) = link_parts(&chars, i) {
                out.push_str(&label);
                i = after;
                continue;
            }
        }
        out.push(chars[i]);
        i += 1;
    }
    out
}

/// Reads `[label]` plus any `(target)` or `[ref]` that follows it, returning
/// the label and the index just past the whole construct.
fn link_parts(chars: &[char], open: usize) -> Option<(String, usize)> {
    let close = (open + 1..chars.len()).find(|i| chars[*i] == ']')?;
    let label: String = chars[open + 1..close].iter().collect();
    let mut after = close + 1;
    match chars.get(after) {
        Some('(') => {
            let end = (after + 1..chars.len()).find(|i| chars[*i] == ')')?;
            after = end + 1;
        }
        Some('[') => {
            let end = (after + 1..chars.len()).find(|i| chars[*i] == ']')?;
            after = end + 1;
        }
        _ => {}
    }
    Some((label, after))
}

fn strip_html(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut depth = 0usize;
    for c in text.chars() {
        match c {
            '<' => depth += 1,
            '>' => depth = depth.saturating_sub(1),
            _ if depth == 0 => out.push(c),
            _ => {}
        }
    }
    out
}

fn decode_entities(text: &str) -> String {
    text.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
        .replace("&hellip;", "…")
        .replace("&mdash;", "—")
        .replace("&ndash;", "–")
}

fn strip_bare_urls(text: &str) -> String {
    text.split_whitespace()
        .filter(|word| !looks_like_url(word))
        .collect::<Vec<_>>()
        .join(" ")
}

fn looks_like_url(word: &str) -> bool {
    let word = word.trim_matches(|c: char| !c.is_alphanumeric() && c != ':' && c != '/' && c != '.');
    word.starts_with("http://") || word.starts_with("https://") || word.starts_with("www.")
}

fn is_bare_url(text: &str) -> bool {
    let mut words = text.split_whitespace();
    match (words.next(), words.next()) {
        (Some(only), None) => looks_like_url(only),
        _ => false,
    }
}

fn collapse_whitespace(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Cut on the last sentence that ends inside the limit, falling back to a word
/// boundary with an ellipsis.
fn truncate_at_sentence(text: &str) -> String {
    if text.chars().count() <= MAX_LEN {
        return text.to_string();
    }
    let clipped: String = text.chars().take(MAX_LEN).collect();

    if let Some(end) = clipped.rfind(['.', '!', '?']) {
        // Keep the terminator itself; `end` is a byte index on a char boundary.
        let sentence = &clipped[..=end];
        if sentence.chars().count() >= MIN_SENTENCE_LEN {
            return sentence.trim().to_string();
        }
    }
    match clipped.rfind(' ') {
        Some(space) => format!("{}…", clipped[..space].trim_end()),
        None => format!("{}…", clipped.trim_end()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drops_markdown_link_reference_definitions() {
        let raw = "[Comments][1]\n\n  [1]: https://news.ycombinator.com/item?id=44123456";
        assert_eq!(excerpt(raw), "Comments");
    }

    #[test]
    fn keeps_link_text_and_drops_the_target() {
        assert_eq!(
            excerpt("See [the release notes](https://example.com/notes) for details."),
            "See the release notes for details."
        );
    }

    #[test]
    fn drops_images_entirely() {
        assert_eq!(excerpt("![a chart](https://example.com/c.png) Revenue doubled."), "Revenue doubled.");
    }

    #[test]
    fn strips_html_and_decodes_entities() {
        assert_eq!(
            excerpt("<p>Rust &amp; C++ <em>both</em> shipped.</p>"),
            "Rust & C++ both shipped."
        );
    }

    #[test]
    fn drops_bare_urls_and_code_blocks() {
        let raw = "Install it:\n```\ncargo add skim\n```\nDocs at https://example.com today.";
        assert_eq!(excerpt(raw), "Install it: Docs at today.");
    }

    #[test]
    fn returns_nothing_for_a_body_that_is_only_a_link() {
        assert_eq!(excerpt("https://example.com/story"), "");
        assert_eq!(excerpt("  [1]: https://example.com/story  "), "");
        assert_eq!(excerpt(""), "");
    }

    #[test]
    fn strips_leading_markers() {
        assert_eq!(excerpt("> ## The Fed held rates"), "The Fed held rates");
        assert_eq!(excerpt("- First point here"), "First point here");
    }

    #[test]
    fn cuts_on_a_sentence_inside_the_limit() {
        let first = "A".repeat(100);
        let raw = format!("{first}. {} more text that runs past the limit", "B".repeat(250));
        assert_eq!(excerpt(&raw), format!("{first}."));
    }

    #[test]
    fn falls_back_to_a_word_boundary_when_no_sentence_fits() {
        let raw = format!("{} tail", "word ".repeat(120));
        let cut = excerpt(&raw);
        assert!(cut.ends_with('…'), "{cut}");
        assert!(cut.chars().count() <= MAX_LEN + 1, "{cut}");
    }
}
