use crate::db::models::{Article, Feed};
use chrono::Utc;
use feed_rs::parser;
use regex::Regex;
use std::collections::HashMap;
use uuid::Uuid;

/// Derive a favicon URL from a site URL using Google's favicon service.
/// Returns None if the URL can't be parsed.
pub fn favicon_url(site_or_feed_url: &str) -> Option<String> {
    let parsed = url::Url::parse(site_or_feed_url).ok()?;
    let host = parsed.host_str()?;
    Some(format!("https://www.google.com/s2/favicons?domain={}&sz=64", host))
}

pub(crate) fn aggregator_comments_url<'a>(mut links: impl Iterator<Item = &'a str>) -> Option<String> {
    links.find_map(|link| {
        let host = url::Url::parse(link).ok()?.host_str()?.to_ascii_lowercase();
        (host == "news.ycombinator.com" || host.ends_with(".ycombinator.com")
            || host == "reddit.com" || host.ends_with(".reddit.com") || host == "redd.it"
            || host == "lobste.rs" || host.ends_with(".lobste.rs"))
            .then(|| link.to_string())
    })
}

/// feed-rs exposes links but drops RSS comments and Atom replies links.
pub(crate) fn extract_discussion_links(xml: &[u8]) -> HashMap<String, String> {
    let source = String::from_utf8_lossy(xml);
    let block_re = Regex::new(r"(?is)<(?:item|entry)\b[^>]*>(.*?)</(?:item|entry)>").unwrap();
    let key_re = Regex::new(r"(?is)<(?:guid|id)\b[^>]*>\s*([^<]+?)\s*</(?:guid|id)>").unwrap();
    let comments_re = Regex::new(r"(?is)<(?:[\w.-]+:)?comments\b[^>]*>\s*([^<]+?)\s*</(?:[\w.-]+:)?comments>").unwrap();
    let replies_re = Regex::new(r#"(?is)<link\b[^>]*\brel\s*=\s*["']replies["'][^>]*\bhref\s*=\s*["']([^"']+)"#).unwrap();
    let replies_re_alt = Regex::new(r#"(?is)<link\b[^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*\brel\s*=\s*["']replies["']"#).unwrap();
    let mut result = HashMap::new();
    for block in block_re.captures_iter(&source) {
        let body = &block[1];
        let Some(key) = key_re.captures(body).map(|m| m[1].trim().to_string()) else { continue };
        let discussion = comments_re.captures(body).map(|m| m[1].trim().to_string())
            .or_else(|| replies_re.captures(body).map(|m| m[1].to_string()))
            .or_else(|| replies_re_alt.captures(body).map(|m| m[1].to_string()));
        if let Some(url) = discussion.filter(|url| !url.is_empty()) { result.insert(key, url); }
    }
    result
}

pub async fn fetch_and_parse_feed(
    feed_url: &str,
    existing_feed_id: Option<&str>,
) -> Result<(Feed, Vec<Article>), String> {
    let client = reqwest::Client::builder()
        .user_agent("Skim/0.1 RSS Reader")
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| format!("Failed to create HTTP client: {}", e))?;

    let response = client
        .get(feed_url)
        .send()
        .await
        .map_err(|e| format!("Failed to fetch feed: {}", e))?;

    let bytes = response
        .bytes()
        .await
        .map_err(|e| format!("Failed to read response: {}", e))?;

    let discussion_links = extract_discussion_links(&bytes);
    let parsed = parser::parse(&bytes[..])
        .map_err(|e| format!("Failed to parse feed: {}", e))?;

    let now = Utc::now().timestamp();
    let feed_id = existing_feed_id
        .map(|s| s.to_string())
        .unwrap_or_else(|| Uuid::new_v4().to_string());

    let title = parsed
        .title
        .map(|t| t.content)
        .unwrap_or_else(|| "Untitled Feed".to_string());

    let site_url = parsed
        .links
        .first()
        .map(|l| l.href.clone());

    let description = parsed.description.map(|d| d.content);

    let icon_url = parsed
        .icon
        .map(|i| i.uri)
        .or_else(|| favicon_url(site_url.as_deref().unwrap_or(feed_url)));

    let feed = Feed {
        id: feed_id.clone(),
        title,
        url: feed_url.to_string(),
        site_url,
        description,
        icon_url,
        feedly_id: None,
        created_at: now,
        updated_at: now,
        last_fetched_at: Some(now),
        folder_id: None,
        opml_category: None,
    };

    let articles: Vec<Article> = parsed
        .entries
        .into_iter()
        .map(|entry| {
            let content_html = entry
                .content
                .as_ref()
                .and_then(|c| c.body.clone())
                .or_else(|| entry.summary.as_ref().map(|s| s.content.clone()));

            let content_text = content_html.as_ref().map(|html| {
                html2text::from_read(html.as_bytes(), 80)
            });

            let article_url = entry.links.first().map(|l| l.href.clone());
            let comments_url = discussion_links
                .get(&entry.id)
                .cloned()
                .or_else(|| aggregator_comments_url(entry.links.iter().map(|link| link.href.as_str())));

            let published_at = entry
                .published
                .or(entry.updated)
                .map(|dt| dt.timestamp());

            let author = entry
                .authors
                .first()
                .map(|a| a.name.clone());

            Article {
                id: Uuid::new_v4().to_string(),
                feed_id: feed_id.clone(),
                title: entry
                    .title
                    .map(|t| t.content)
                    .unwrap_or_else(|| "Untitled".to_string()),
                url: article_url,
                author,
                content_html,
                content_text,
                published_at,
                fetched_at: now,
                is_read: false,
                is_starred: false,
                feedly_entry_id: None,
                comments_url,
            }
        })
        .collect();

    Ok((feed, articles))
}

#[cfg(test)]
mod tests {
    use super::{aggregator_comments_url, extract_discussion_links};
    use feed_rs::parser;

    #[test]
    fn preserves_external_primary_and_discussion_alias() {
        let links = [
            "https://example.com/story",
            "https://news.ycombinator.com/item?id=123",
        ];
        assert_eq!(aggregator_comments_url(links.into_iter()), Some(links[1].to_string()));
    }

    #[test]
    fn parses_rss_comments_and_atom_replies_aliases() {
        let rss = br#"<rss version="2.0"><channel><title>t</title><item><guid>rss-1</guid><link>https://example.com/story</link><comments>https://news.ycombinator.com/item?id=1</comments></item></channel></rss>"#;
        let atom = br#"<feed xmlns="http://www.w3.org/2005/Atom"><entry><id>atom-1</id><link href="https://example.com/story"/><link rel="replies" href="https://www.reddit.com/r/rust/comments/1/post"/></entry></feed>"#;
        let rss_parsed = parser::parse(&rss[..]).expect("parse rss fixture");
        let atom_parsed = parser::parse(&atom[..]).expect("parse atom fixture");
        let rss_links = extract_discussion_links(rss);
        let atom_links = extract_discussion_links(atom);
        assert_eq!(rss_links.get(&rss_parsed.entries[0].id).map(String::as_str), Some("https://news.ycombinator.com/item?id=1"));
        assert_eq!(atom_links.get(&atom_parsed.entries[0].id).map(String::as_str), Some("https://www.reddit.com/r/rust/comments/1/post"));
    }
}
