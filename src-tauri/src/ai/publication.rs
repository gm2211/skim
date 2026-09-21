//! Turning a feed's own title into something printable as a publication name.
//!
//! Feed titles are whatever the publisher put in the XML. Some are the format
//! ("RSS 2.0", "Atom"), some are a name plus a paragraph of description
//! ("Java News/Tech/Discussion/etc. No programming help, no learning Java").
//! Neither reads as a byline, so the front page derives a short name instead.

/// Feed titles that name the syndication format rather than the publication.
const FORMAT_TITLES: &[&str] = &[
    "rss", "rss 1.0", "rss 2.0", "rss feed", "atom", "atom 1.0", "atom feed", "feed", "xml",
    "index", "untitled", "no title", "rdf",
];

/// Separators after which a feed title has stopped naming itself and started
/// describing itself.
const SEPARATORS: &[&str] = &[" - ", " – ", " — ", " | ", " :: ", " · ", ". "];

const MAX_LEN: usize = 32;

/// A short publication name for an article, derived from its feed title and,
/// when that title is useless, the article's own URL.
pub fn publication_name(feed_title: &str, article_url: Option<&str>) -> String {
    let trimmed = feed_title.trim();

    if trimmed.is_empty() || FORMAT_TITLES.contains(&trimmed.to_lowercase().as_str()) {
        if let Some(host) = host_of(article_url) {
            return host;
        }
        if trimmed.is_empty() {
            return "Unknown source".to_string();
        }
    }

    truncate(head(trimmed))
}

/// The part of a title before it turns into a description.
fn head(title: &str) -> &str {
    let mut best = title;
    for sep in SEPARATORS {
        if let Some(index) = title.find(sep) {
            let candidate = title[..index].trim();
            // A two-character head is an artifact of the split, not a name.
            if candidate.chars().count() >= 3 && candidate.len() < best.len() {
                best = candidate;
            }
        }
    }
    best.trim()
}

/// The host of a URL, without the `www.` that no masthead prints.
fn host_of(url: Option<&str>) -> Option<String> {
    let url = url?.trim();
    let without_scheme = url
        .split_once("://")
        .map(|(_, rest)| rest)
        .unwrap_or(url);
    let host = without_scheme
        .split(['/', '?', '#'])
        .next()?
        .split('@')
        .next_back()?
        .split(':')
        .next()?;
    let host = host.strip_prefix("www.").unwrap_or(host);
    if host.is_empty() || !host.contains('.') {
        return None;
    }
    Some(host.to_string())
}

/// Cap the name, cutting on a word boundary where there is one nearby.
fn truncate(name: &str) -> String {
    if name.chars().count() <= MAX_LEN {
        return name.to_string();
    }
    let clipped: String = name.chars().take(MAX_LEN).collect();
    let cut = clipped
        .rfind(' ')
        .filter(|index| *index >= MAX_LEN / 2)
        .unwrap_or(clipped.len());
    format!("{}…", clipped[..cut].trim_end())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_a_real_publication_name() {
        assert_eq!(publication_name("Hacker News", None), "Hacker News");
    }

    #[test]
    fn falls_back_to_the_host_for_format_titles() {
        assert_eq!(
            publication_name("RSS 2.0", Some("https://www.theverge.com/2026/1/1/post")),
            "theverge.com"
        );
        assert_eq!(publication_name("Atom", Some("http://lwn.net/Articles/1")), "lwn.net");
    }

    #[test]
    fn keeps_the_format_title_when_there_is_no_usable_url() {
        assert_eq!(publication_name("RSS 2.0", None), "RSS 2.0");
        assert_eq!(publication_name("RSS 2.0", Some("not a url")), "RSS 2.0");
    }

    #[test]
    fn names_an_untitled_feed_when_nothing_else_is_known() {
        assert_eq!(publication_name("   ", None), "Unknown source");
    }

    #[test]
    fn drops_the_description_after_a_separator() {
        assert_eq!(
            publication_name(
                "Java News/Tech/Discussion/etc. No programming help, no learning Java",
                None
            ),
            "Java News/Tech/Discussion/etc"
        );
        assert_eq!(
            publication_name("Simon Willison's Weblog - Blog entries", None),
            "Simon Willison's Weblog"
        );
    }

    #[test]
    fn ignores_a_separator_that_leaves_nothing_behind() {
        assert_eq!(publication_name("A - Journal of Nothing", None), "A - Journal of Nothing");
    }

    #[test]
    fn truncates_on_a_word_boundary() {
        assert_eq!(
            publication_name("The Exceedingly Long Quarterly Review of Things", None),
            "The Exceedingly Long Quarterly…"
        );
    }
}
