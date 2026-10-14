//! Feed discovery: turn a website address, a feed address, or a few words into
//! feeds a reader can subscribe to.
//!
//! - A website URL is fetched and its `<link rel="alternate">` feeds are read,
//!   plus known patterns for sites that hide their feeds (Reddit, YouTube,
//!   GitHub, Hacker News, Medium, Mastodon, Bluesky). Common paths such as
//!   `/feed` and `/atom.xml` are tried only when nothing else turns up.
//! - Words are searched in Feedly's public feed index, with the built-in
//!   catalog (`shared/feed-catalog.json`) as the offline fallback.

use super::fetcher::{fetch_bytes, http_client, parse_feed_bytes};
use futures_util::future::join_all;
use regex::Regex;
use serde::{Deserialize, Serialize};

const CATALOG_JSON: &str = include_str!("../../../shared/feed-catalog.json");
const PREVIEW_ITEMS: usize = 5;
const MAX_CANDIDATES: usize = 12;

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct FeedPreviewItem {
    pub title: String,
    pub url: Option<String>,
    pub published_at: Option<i64>,
}

#[derive(Debug, Clone, Serialize)]
pub struct DiscoveredFeed {
    pub url: String,
    pub title: String,
    pub site_url: Option<String>,
    pub description: Option<String>,
    pub icon_url: Option<String>,
    /// Feedly follower count, when the result came from search.
    pub subscribers: Option<i64>,
    /// Latest headlines. Empty until the feed has been fetched.
    pub items: Vec<FeedPreviewItem>,
    pub already_subscribed: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CatalogFeed {
    pub title: String,
    pub url: String,
    pub site: String,
    pub description: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CatalogTopic {
    pub id: String,
    pub name: String,
    pub feeds: Vec<CatalogFeed>,
}

#[derive(Deserialize)]
struct Catalog {
    topics: Vec<CatalogTopic>,
}

pub fn catalog() -> Vec<CatalogTopic> {
    serde_json::from_str::<Catalog>(CATALOG_JSON)
        .map(|c| c.topics)
        .unwrap_or_default()
}

/// True when the input reads as an address rather than search words:
/// it has a scheme, or it is one token with a dot and a letter-only suffix
/// (`theverge.com`, `blog.rust-lang.org/feed`). `r/rust` counts too.
pub fn looks_like_url(input: &str) -> bool {
    let s = input.trim();
    if s.is_empty() || s.chars().any(char::is_whitespace) {
        return false;
    }
    if s.contains("://") || Regex::new(r"^/?r/[A-Za-z0-9_]+/?$").unwrap().is_match(s) {
        return true;
    }
    let host = s.split(['/', '?', '#']).next().unwrap_or("");
    let host = host.rsplit('@').next().unwrap_or(host);
    match host.rsplit_once('.') {
        Some((name, tld)) => {
            !name.is_empty() && tld.len() >= 2 && tld.chars().all(|c| c.is_ascii_alphabetic())
        }
        None => false,
    }
}

/// Adds `https://` to bare addresses and expands `r/name` to Reddit.
pub fn normalize_input_url(input: &str) -> String {
    let s = input.trim();
    let sub = Regex::new(r"^/?r/([A-Za-z0-9_]+)/?$").unwrap();
    if let Some(c) = sub.captures(s) {
        return format!("https://www.reddit.com/r/{}/", &c[1]);
    }
    if s.contains("://") {
        s.to_string()
    } else {
        format!("https://{}", s)
    }
}

/// Feed URLs for sites whose feeds follow a known pattern.
pub fn site_specific_feeds(page_url: &str) -> Vec<String> {
    let Ok(url) = url::Url::parse(page_url) else { return Vec::new() };
    let Some(host) = url.host_str().map(|h| h.to_ascii_lowercase()) else { return Vec::new() };
    let bare = host.trim_start_matches("www.").trim_start_matches("old.").trim_start_matches("m.");
    let segs: Vec<&str> = url.path_segments().map(|s| s.filter(|p| !p.is_empty()).collect()).unwrap_or_default();
    let mut out = Vec::new();
    match bare {
        "reddit.com" => match segs.as_slice() {
            ["r", sub, ..] => out.push(format!("https://www.reddit.com/r/{}/.rss", sub)),
            ["user" | "u", name, ..] => out.push(format!("https://www.reddit.com/user/{}/.rss", name)),
            [] => out.push("https://www.reddit.com/.rss".to_string()),
            _ => {}
        },
        "youtube.com" => {
            if let Some((_, list)) = url.query_pairs().find(|(k, _)| k == "list") {
                out.push(format!("https://www.youtube.com/feeds/videos.xml?playlist_id={}", list));
            }
            match segs.as_slice() {
                ["channel", id, ..] => out.push(format!("https://www.youtube.com/feeds/videos.xml?channel_id={}", id)),
                ["user", name, ..] => out.push(format!("https://www.youtube.com/feeds/videos.xml?user={}", name)),
                _ => {}
            }
        }
        "news.ycombinator.com" => {
            out.push("https://news.ycombinator.com/rss".to_string());
            out.push("https://hnrss.org/best".to_string());
            out.push("https://hnrss.org/newest?points=100".to_string());
        }
        "github.com" => match segs.as_slice() {
            [owner, repo, ..] => {
                out.push(format!("https://github.com/{}/{}/releases.atom", owner, repo));
                out.push(format!("https://github.com/{}/{}/commits.atom", owner, repo));
            }
            [user] => out.push(format!("https://github.com/{}.atom", user)),
            _ => {}
        },
        "medium.com" => match segs.as_slice() {
            [first, ..] => out.push(format!("https://medium.com/feed/{}", first)),
            [] => {}
        },
        "bsky.app" => {
            if let ["profile", handle, ..] = segs.as_slice() {
                out.push(format!("https://bsky.app/profile/{}/rss", handle));
            }
        }
        "lobste.rs" => out.push("https://lobste.rs/rss".to_string()),
        _ => {
            if bare.ends_with(".medium.com") {
                out.push(format!("https://{}/feed", host));
            } else if let [first] = segs.as_slice() {
                // Mastodon and other fediverse profiles: /@user -> /@user.rss
                if first.starts_with('@') && first.len() > 1 {
                    out.push(format!("https://{}/{}.rss", host, first));
                }
            }
        }
    }
    out
}

/// `<link rel="alternate" type="application/rss+xml" href="...">` feeds in a page.
pub fn feed_links_in_html(html: &str, base_url: &str) -> Vec<String> {
    let base = url::Url::parse(base_url).ok();
    let tag_re = Regex::new(r"(?is)<link\b[^>]*>").unwrap();
    let attr_re = Regex::new(r#"(?is)([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)')"#).unwrap();
    let mut out = Vec::new();
    for tag in tag_re.find_iter(html) {
        let mut rel = String::new();
        let mut kind = String::new();
        let mut href = None;
        for c in attr_re.captures_iter(tag.as_str()) {
            let value = c.get(2).or_else(|| c.get(3)).map(|m| m.as_str()).unwrap_or("");
            match c[1].to_ascii_lowercase().as_str() {
                "rel" => rel = value.to_ascii_lowercase(),
                "type" => kind = value.to_ascii_lowercase(),
                "href" => href = Some(decode_html_attr(value)),
                _ => {}
            }
        }
        let is_feed = kind.contains("rss") || kind.contains("atom") || kind.contains("feed+json");
        if !rel.split_whitespace().any(|r| r == "alternate") || !is_feed {
            continue;
        }
        let Some(href) = href.filter(|h| !h.is_empty()) else { continue };
        let resolved = match &base {
            Some(b) => b.join(&href).map(|u| u.to_string()).unwrap_or(href),
            None => href,
        };
        if !out.contains(&resolved) {
            out.push(resolved);
        }
    }
    // YouTube handle pages (/@name) carry the channel id in page data even when
    // the alternate link is missing from the served HTML.
    if out.is_empty() {
        let channel_re = Regex::new(r#""(?:channelId|externalId)":"(UC[\w-]{22})""#).unwrap();
        if base_url.contains("youtube.com") {
            if let Some(c) = channel_re.captures(html) {
                out.push(format!("https://www.youtube.com/feeds/videos.xml?channel_id={}", &c[1]));
            }
        }
    }
    out
}

fn decode_html_attr(value: &str) -> String {
    value.replace("&amp;", "&").replace("&#38;", "&").replace("&quot;", "\"").replace("&#39;", "'")
}

pub fn common_feed_paths(page_url: &str) -> Vec<String> {
    let Ok(url) = url::Url::parse(page_url) else { return Vec::new() };
    let origin = url.origin().ascii_serialization();
    let mut out: Vec<String> = ["/feed", "/rss", "/feed.xml", "/rss.xml", "/atom.xml", "/index.xml", "/feed.json", "/feeds/posts/default"]
        .iter()
        .map(|p| format!("{}{}", origin, p))
        .collect();
    let path = url.path().trim_end_matches('/');
    if !path.is_empty() {
        out.insert(0, format!("{}{}/feed", origin, path));
    }
    out
}

fn to_discovered(bytes: &[u8], feed_url: &str) -> Option<DiscoveredFeed> {
    let (feed, articles) = parse_feed_bytes(bytes, feed_url, None).ok()?;
    let site_url = feed.site_url.filter(|s| s != feed_url);
    Some(DiscoveredFeed {
        url: feed_url.to_string(),
        title: feed.title,
        icon_url: feed.icon_url,
        site_url,
        description: feed.description.map(|d| clean_text(&d)).filter(|d| !d.is_empty()),
        subscribers: None,
        items: articles
            .into_iter()
            .take(PREVIEW_ITEMS)
            .map(|a| FeedPreviewItem { title: clean_text(&a.title), url: a.url, published_at: a.published_at })
            .collect(),
        already_subscribed: false,
    })
}

fn clean_text(s: &str) -> String {
    let no_tags = Regex::new(r"(?s)<[^>]*>").unwrap().replace_all(s, " ");
    let decoded = no_tags
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&nbsp;", " ");
    decoded.split_whitespace().collect::<Vec<_>>().join(" ")
}

async fn probe(client: &reqwest::Client, candidates: Vec<String>) -> Vec<DiscoveredFeed> {
    let fetches = candidates.into_iter().take(MAX_CANDIDATES).map(|url| async move {
        let (_, bytes) = fetch_bytes(client, &url).await.ok()?;
        to_discovered(&bytes, &url)
    });
    join_all(fetches).await.into_iter().flatten().collect()
}

/// Finds the feeds behind a website or feed address.
pub async fn discover(input: &str) -> Result<Vec<DiscoveredFeed>, String> {
    let page_url = normalize_input_url(input);
    url::Url::parse(&page_url).map_err(|_| format!("\"{}\" is not a web address.", input.trim()))?;
    let client = http_client(12)?;

    let special = site_specific_feeds(&page_url);
    let page = fetch_bytes(&client, &page_url).await;

    let mut candidates = Vec::new();
    match &page {
        Ok((final_url, bytes)) => {
            if let Some(feed) = to_discovered(bytes, &page_url) {
                // The address is itself a feed.
                return Ok(vec![feed]);
            }
            let html = String::from_utf8_lossy(bytes);
            candidates.extend(feed_links_in_html(&html, final_url));
            candidates.extend(site_specific_feeds(final_url));
        }
        Err(_) => {}
    }
    candidates.extend(special);
    dedup(&mut candidates);

    let mut found = probe(&client, candidates).await;
    if found.is_empty() {
        let base = page.as_ref().map(|(u, _)| u.clone()).unwrap_or(page_url.clone());
        found = probe(&client, common_feed_paths(&base)).await;
        // Several common paths often redirect to the same feed.
        let mut seen = std::collections::HashSet::new();
        found.retain(|f| seen.insert((f.title.clone(), f.items.first().map(|i| i.title.clone()))));
    }
    if found.is_empty() {
        return match page {
            Err(e) => Err(e),
            Ok(_) => Err("No feeds found on that page.".to_string()),
        };
    }
    Ok(found)
}

/// Fetches one feed for its preview headlines.
pub async fn preview(feed_url: &str) -> Result<DiscoveredFeed, String> {
    let client = http_client(12)?;
    let (_, bytes) = fetch_bytes(&client, feed_url).await?;
    to_discovered(&bytes, feed_url).ok_or_else(|| "That address is not a feed.".to_string())
}

fn dedup(urls: &mut Vec<String>) {
    let mut seen = std::collections::HashSet::new();
    urls.retain(|u| seen.insert(u.trim_end_matches('/').to_string()));
}

#[derive(Deserialize)]
struct FeedlySearch {
    #[serde(default)]
    results: Vec<FeedlyResult>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FeedlyResult {
    feed_id: Option<String>,
    title: Option<String>,
    website: Option<String>,
    description: Option<String>,
    subscribers: Option<i64>,
    icon_url: Option<String>,
    visual_url: Option<String>,
}

fn parse_feedly_search(json: &str) -> Vec<DiscoveredFeed> {
    let Ok(parsed) = serde_json::from_str::<FeedlySearch>(json) else { return Vec::new() };
    parsed
        .results
        .into_iter()
        .filter_map(|r| {
            let url = r.feed_id?.strip_prefix("feed/")?.to_string();
            let site_url = r.website.clone();
            let icon_url = r
                .icon_url
                .or(r.visual_url)
                .or_else(|| super::fetcher::favicon_url(site_url.as_deref().unwrap_or(&url)));
            Some(DiscoveredFeed {
                title: r.title.map(|t| clean_text(&t)).filter(|t| !t.is_empty()).unwrap_or_else(|| url.clone()),
                url,
                site_url,
                description: r.description.map(|d| clean_text(&d)).filter(|d| !d.is_empty()),
                icon_url,
                subscribers: r.subscribers,
                items: Vec::new(),
                already_subscribed: false,
            })
        })
        .collect()
}

/// Catalog feeds whose title, description, or topic contains every search word.
pub fn search_catalog(query: &str) -> Vec<DiscoveredFeed> {
    let words: Vec<String> = query.split_whitespace().map(|w| w.to_lowercase()).collect();
    if words.is_empty() {
        return Vec::new();
    }
    let mut out = Vec::new();
    for topic in catalog() {
        for feed in topic.feeds {
            let hay = format!("{} {} {} {}", feed.title, feed.description, topic.name, feed.site).to_lowercase();
            if words.iter().all(|w| hay.contains(w)) && !out.iter().any(|f: &DiscoveredFeed| f.url == feed.url) {
                out.push(catalog_entry(&feed));
            }
        }
    }
    out
}

pub fn catalog_entry(feed: &CatalogFeed) -> DiscoveredFeed {
    DiscoveredFeed {
        url: feed.url.clone(),
        title: feed.title.clone(),
        site_url: Some(feed.site.clone()),
        description: Some(feed.description.clone()),
        icon_url: super::fetcher::favicon_url(&feed.site),
        subscribers: None,
        items: Vec::new(),
        already_subscribed: false,
    }
}

/// Searches feeds by topic or name. Catalog matches lead, then Feedly results.
pub async fn search(query: &str) -> Result<Vec<DiscoveredFeed>, String> {
    let q = query.trim();
    if q.is_empty() {
        return Ok(Vec::new());
    }
    let mut results = search_catalog(q);
    let client = http_client(10)?;
    let url = format!(
        "https://cloud.feedly.com/v3/search/feeds?query={}&count=30&locale=en",
        urlencoding::encode(q)
    );
    let feedly = match client.get(&url).send().await {
        Ok(resp) if resp.status().is_success() => resp.text().await.map(|t| parse_feedly_search(&t)).unwrap_or_default(),
        Ok(resp) => {
            log::warn!("Feedly search returned HTTP {}", resp.status());
            Vec::new()
        }
        Err(e) => {
            log::warn!("Feedly search failed: {}", e);
            Vec::new()
        }
    };
    for f in feedly {
        let key = f.url.trim_end_matches('/').to_string();
        if !results.iter().any(|r| r.url.trim_end_matches('/') == key) {
            results.push(f);
        }
    }
    Ok(results)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_urls_and_words() {
        assert!(looks_like_url("theverge.com"));
        assert!(looks_like_url("https://example.com"));
        assert!(looks_like_url("blog.rust-lang.org/feed"));
        assert!(looks_like_url("r/rust"));
        assert!(!looks_like_url("rust programming"));
        assert!(!looks_like_url("rust"));
        assert!(!looks_like_url("v1.2"));
        assert!(!looks_like_url(""));
    }

    #[test]
    fn normalizes_bare_addresses() {
        assert_eq!(normalize_input_url("theverge.com"), "https://theverge.com");
        assert_eq!(normalize_input_url(" r/rust "), "https://www.reddit.com/r/rust/");
        assert_eq!(normalize_input_url("http://x.org/a"), "http://x.org/a");
    }

    #[test]
    fn knows_site_patterns() {
        assert_eq!(site_specific_feeds("https://www.reddit.com/r/rust/"), vec!["https://www.reddit.com/r/rust/.rss"]);
        assert_eq!(site_specific_feeds("https://old.reddit.com/u/spez"), vec!["https://www.reddit.com/user/spez/.rss"]);
        assert_eq!(
            site_specific_feeds("https://www.youtube.com/channel/UCabcdefghijklmnopqrstuv"),
            vec!["https://www.youtube.com/feeds/videos.xml?channel_id=UCabcdefghijklmnopqrstuv"]
        );
        assert_eq!(
            site_specific_feeds("https://www.youtube.com/playlist?list=PL123"),
            vec!["https://www.youtube.com/feeds/videos.xml?playlist_id=PL123"]
        );
        assert_eq!(
            site_specific_feeds("https://github.com/rust-lang/rust"),
            vec!["https://github.com/rust-lang/rust/releases.atom", "https://github.com/rust-lang/rust/commits.atom"]
        );
        assert_eq!(site_specific_feeds("https://github.com/gm2211"), vec!["https://github.com/gm2211.atom"]);
        assert_eq!(site_specific_feeds("https://medium.com/@someone"), vec!["https://medium.com/feed/@someone"]);
        assert_eq!(site_specific_feeds("https://mastodon.social/@Gargron"), vec!["https://mastodon.social/@Gargron.rss"]);
        assert_eq!(site_specific_feeds("https://bsky.app/profile/a.bsky.social"), vec!["https://bsky.app/profile/a.bsky.social/rss"]);
        assert_eq!(site_specific_feeds("https://news.ycombinator.com/")[0], "https://news.ycombinator.com/rss");
        assert!(site_specific_feeds("https://example.com/about").is_empty());
    }

    #[test]
    fn reads_alternate_links() {
        let html = r#"<html><head>
            <link rel="stylesheet" href="/a.css">
            <link rel="alternate" type="application/rss+xml" title="Posts" href="/feed.xml">
            <link type='application/atom+xml' href='https://cdn.example.com/atom?a=1&amp;b=2' rel='alternate'>
            <link rel="alternate" type="text/html" href="/fr">
            <link rel="alternate" type="application/feed+json" href="feed.json">
        </head></html>"#;
        assert_eq!(
            feed_links_in_html(html, "https://example.com/blog/"),
            vec![
                "https://example.com/feed.xml",
                "https://cdn.example.com/atom?a=1&b=2",
                "https://example.com/blog/feed.json",
            ]
        );
    }

    #[test]
    fn finds_youtube_channel_id_in_page_data() {
        let html = r#"<script>var x = {"externalId":"UC1234567890abcdefghijkl"};</script>"#;
        assert_eq!(
            feed_links_in_html(html, "https://www.youtube.com/@someone"),
            vec!["https://www.youtube.com/feeds/videos.xml?channel_id=UC1234567890abcdefghijkl"]
        );
    }

    #[test]
    fn common_paths_include_section_feed() {
        let paths = common_feed_paths("https://example.com/tech/");
        assert_eq!(paths[0], "https://example.com/tech/feed");
        assert!(paths.contains(&"https://example.com/atom.xml".to_string()));
    }

    #[test]
    fn builds_preview_from_feed_bytes() {
        let rss = br#"<?xml version="1.0"?><rss version="2.0"><channel><title>Demo &amp; Co</title>
            <link>https://demo.example</link><description>About &lt;b&gt;things&lt;/b&gt;</description>
            <item><title>One</title><link>https://demo.example/1</link></item>
            <item><title>Two</title><link>https://demo.example/2</link></item>
            </channel></rss>"#;
        let feed = to_discovered(rss, "https://demo.example/feed").unwrap();
        assert_eq!(feed.title, "Demo & Co");
        assert_eq!(feed.description.as_deref(), Some("About things"));
        assert_eq!(feed.items.len(), 2);
        assert_eq!(feed.items[0].title, "One");
        assert!(to_discovered(b"<html><body>hi</body></html>", "https://x.org").is_none());
    }

    #[test]
    fn parses_feedly_search_results() {
        let json = r#"{"results":[
            {"feedId":"feed/https://www.theverge.com/rss/index.xml","title":"The Verge","website":"https://www.theverge.com","subscribers":1200000,"iconUrl":"https://i/v.png","description":"Tech"},
            {"feedId":"user/123/category/x","title":"not a feed"}
        ]}"#;
        let r = parse_feedly_search(json);
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].url, "https://www.theverge.com/rss/index.xml");
        assert_eq!(r[0].subscribers, Some(1_200_000));
        assert!(parse_feedly_search("not json").is_empty());
    }

    #[test]
    fn catalog_loads_and_searches() {
        let topics = catalog();
        assert!(topics.len() >= 8);
        assert!(topics.iter().all(|t| !t.feeds.is_empty()));
        let hits = search_catalog("apple");
        assert!(hits.iter().any(|f| f.title == "Daring Fireball"));
        assert!(search_catalog("zzzz-nothing").is_empty());
    }
}
