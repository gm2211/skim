use reqwest::Client;
use serde::Serialize;
use serde_json::Value;
use tauri::command;
use url::Url;

const DEFAULT_COMMENT_LIMIT: usize = 10;
/// Deepest reply level kept (0 = top-level comment).
const MAX_COMMENT_DEPTH: i64 = 4;
/// Upper bound on comments returned for one thread, replies included.
const MAX_THREAD_COMMENTS: usize = 300;

#[derive(Debug, Clone, Serialize)]
/// Comments come back flattened in thread order: each comment is followed by
/// its replies, which carry a larger `depth`.
pub struct AggregatorComment {
    pub id: String,
    pub author: String,
    pub score: Option<i64>,
    pub body: String,
    pub depth: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct AggregatorDetails {
    pub kind: String,
    pub selftext: Option<String>,
    pub external_url: Option<String>,
    pub points: Option<i64>,
    pub comment_count: Option<i64>,
    pub comments: Vec<AggregatorComment>,
}

/// Reddit asks API clients for a `platform:app:version (by /u/user)` agent
/// and throttles generic ones first.
const REDDIT_USER_AGENT: &str = "desktop:app.skim.reader:v1.0 (by /u/skim_reader)";

#[command]
pub async fn fetch_aggregator_details(
    url: String,
    limit: Option<usize>,
) -> Result<Option<AggregatorDetails>, String> {
    let Some(parsed) = Url::parse(&url).ok() else {
        return Ok(None);
    };
    let Some(kind) = aggregator_kind(&parsed) else {
        return Ok(None);
    };
    let limit = limit.unwrap_or(DEFAULT_COMMENT_LIMIT).clamp(1, 50);
    let client = Client::builder()
        .user_agent("Skim/1.0 (RSS reader)")
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|error| format!("Could not create aggregator request: {error}"))?;

    match kind {
        "hacker_news" => fetch_hacker_news(&client, &parsed, limit).await,
        "reddit" => fetch_reddit(&client, &parsed, limit).await,
        "lobsters" => fetch_lobsters(&client, &parsed, limit).await,
        _ => Ok(None),
    }
}

fn aggregator_kind(url: &Url) -> Option<&'static str> {
    let host = url.host_str()?.to_ascii_lowercase();
    if host == "news.ycombinator.com" || host.ends_with(".ycombinator.com") {
        Some("hacker_news")
    } else if host == "reddit.com"
        || host == "www.reddit.com"
        || host == "old.reddit.com"
        || host == "new.reddit.com"
        || host == "redd.it"
        || host.ends_with(".reddit.com")
    {
        Some("reddit")
    } else if host == "lobste.rs" || host.ends_with(".lobste.rs") {
        Some("lobsters")
    } else {
        None
    }
}

async fn get_json(client: &Client, url: &str) -> Result<Value, String> {
    client
        .get(url)
        .send()
        .await
        .map_err(|error| format!("Could not fetch aggregator details: {error}"))?
        .error_for_status()
        .map_err(|error| format!("Could not fetch aggregator details: {error}"))?
        .json::<Value>()
        .await
        .map_err(|error| format!("Aggregator returned invalid JSON: {error}"))
}

async fn fetch_hacker_news(
    client: &Client,
    url: &Url,
    limit: usize,
) -> Result<Option<AggregatorDetails>, String> {
    let Some(story_id) = url
        .query_pairs()
        .find(|(name, _)| name == "id")
        .map(|(_, value)| value.into_owned())
    else {
        return Ok(None);
    };
    let value = get_json(client, &format!("https://hn.algolia.com/api/v1/items/{story_id}")).await?;
    let children = value.get("children").and_then(Value::as_array);
    let mut comments = Vec::new();
    for child in children.into_iter().flatten().take(limit) {
        push_hn_thread(child, 0, &mut comments);
    }
    Ok(Some(AggregatorDetails {
        kind: "hacker_news".into(),
        selftext: value.get("text").and_then(Value::as_str).map(clean_html).filter(|text| !text.is_empty()),
        external_url: http_url(value.get("url").and_then(Value::as_str)),
        points: value.get("points").and_then(Value::as_i64),
        comment_count: children.map(|items| count_hn_comments(items)),
        comments,
    }))
}

fn count_hn_comments(items: &[Value]) -> i64 {
    items
        .iter()
        .map(|item| {
            let own = i64::from(item.get("text").and_then(Value::as_str).is_some());
            own + item.get("children").and_then(Value::as_array).map_or(0, |c| count_hn_comments(c))
        })
        .sum()
}

fn push_hn_thread(value: &Value, depth: i64, out: &mut Vec<AggregatorComment>) {
    if out.len() >= MAX_THREAD_COMMENTS {
        return;
    }
    // A deleted comment drops its whole subtree; its replies would read as
    // answers to the wrong parent.
    let Some(comment) = hn_comment(value, depth) else {
        return;
    };
    out.push(comment);
    if depth >= MAX_COMMENT_DEPTH {
        return;
    }
    for child in value.get("children").and_then(Value::as_array).into_iter().flatten() {
        push_hn_thread(child, depth + 1, out);
    }
}

fn hn_comment(value: &Value, depth: i64) -> Option<AggregatorComment> {
    let id = value.get("id").and_then(value_string)?;
    let author = value.get("author").and_then(Value::as_str)?.to_owned();
    let body = clean_html(value.get("text").and_then(Value::as_str)?);
    if body.is_empty() {
        return None;
    }
    Some(AggregatorComment {
        id,
        author,
        score: value.get("points").and_then(Value::as_i64),
        body,
        depth,
    })
}

fn http_url(value: Option<&str>) -> Option<String> {
    let parsed = Url::parse(value?).ok()?;
    matches!(parsed.scheme(), "http" | "https").then(|| parsed.to_string())
}

async fn fetch_reddit(
    client: &Client,
    url: &Url,
    limit: usize,
) -> Result<Option<AggregatorDetails>, String> {
    let value = match fetch_reddit_json(client, url, limit).await {
        Ok(value) => value,
        // Reddit blocks anonymous JSON for some networks while its RSS keeps
        // working (Skim already reads subreddits that way), so fall back to
        // the thread's comment feed: no scores or nesting, but real comments.
        Err(json_error) => {
            return match fetch_reddit_rss(client, url, limit).await {
                Ok(details) => Ok(Some(details)),
                Err(_) => Err(json_error),
            };
        }
    };
    let Some(post) = value
        .as_array()
        .and_then(|root| root.first())
        .and_then(|listing| listing.get("data"))
        .and_then(|data| data.get("children"))
        .and_then(Value::as_array)
        .and_then(|children| children.first())
        .and_then(|child| child.get("data"))
    else {
        return Ok(None);
    };
    let selftext = post
        .get("selftext")
        .and_then(Value::as_str)
        .filter(|text| !text.is_empty() && *text != "[deleted]" && *text != "[removed]")
        .map(str::to_owned);
    let external_url = if post.get("is_self").and_then(Value::as_bool).unwrap_or(false) {
        None
    } else {
        post.get("url_overridden_by_dest")
            .or_else(|| post.get("url"))
            .and_then(Value::as_str)
            .filter(|candidate| Url::parse(candidate).ok().and_then(|parsed| aggregator_kind(&parsed)).is_none())
            .and_then(|candidate| http_url(Some(candidate)))
    };
    Ok(Some(AggregatorDetails {
        kind: "reddit".into(),
        selftext,
        external_url,
        points: post.get("score").and_then(Value::as_i64),
        comment_count: post.get("num_comments").and_then(Value::as_i64),
        comments: reddit_comments(&value, limit),
    }))
}

fn reddit_comments(value: &Value, limit: usize) -> Vec<AggregatorComment> {
    let mut comments = Vec::new();
    for child in reddit_listing_children(value.as_array().and_then(|root| root.get(1)))
        .iter()
        .filter(|child| child.get("kind").and_then(Value::as_str) != Some("more"))
        .take(limit)
    {
        push_reddit_thread(child, 0, &mut comments);
    }
    comments
}

fn reddit_listing_children(listing: Option<&Value>) -> Vec<Value> {
    listing
        .and_then(|listing| listing.get("data"))
        .and_then(|data| data.get("children"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
}

fn push_reddit_thread(value: &Value, depth: i64, out: &mut Vec<AggregatorComment>) {
    if out.len() >= MAX_THREAD_COMMENTS || value.get("kind").and_then(Value::as_str) == Some("more") {
        return;
    }
    let Some(comment) = reddit_comment(value, depth) else {
        return;
    };
    out.push(comment);
    if depth >= MAX_COMMENT_DEPTH {
        return;
    }
    // `replies` is "" when a comment has none, otherwise a nested listing.
    let replies = value.get("data").and_then(|data| data.get("replies"));
    for reply in reddit_listing_children(replies) {
        push_reddit_thread(&reply, depth + 1, out);
    }
}

/// Reddit refuses or rate-limits anonymous JSON requests unpredictably, so try
/// its documented agent on www first and old.reddit as a second door.
async fn fetch_reddit_json(client: &Client, url: &Url, limit: usize) -> Result<Value, String> {
    let mut last_error = String::new();
    for json_url in reddit_json_urls(url, limit) {
        let response = client
            .get(&json_url)
            .header(reqwest::header::USER_AGENT, REDDIT_USER_AGENT)
            .header(reqwest::header::ACCEPT, "application/json")
            .send()
            .await;
        match response.and_then(|response| response.error_for_status()) {
            Ok(response) => match response.json::<Value>().await {
                Ok(value) if value.is_array() => return Ok(value),
                Ok(_) => last_error = "Reddit returned an unexpected response".into(),
                Err(error) => last_error = format!("Reddit returned invalid JSON: {error}"),
            },
            Err(error) => last_error = format!("Could not fetch Reddit discussion: {error}"),
        }
    }
    Err(last_error)
}

async fn fetch_reddit_rss(client: &Client, url: &Url, limit: usize) -> Result<AggregatorDetails, String> {
    let bytes = client
        .get(reddit_rss_url(url, limit))
        .send()
        .await
        .and_then(|response| response.error_for_status())
        .map_err(|error| format!("Could not fetch Reddit discussion feed: {error}"))?
        .bytes()
        .await
        .map_err(|error| format!("Could not read Reddit discussion feed: {error}"))?;
    let comments = reddit_rss_comments(&bytes, limit)?;
    if comments.is_empty() {
        return Err("Reddit's discussion feed had no comments".into());
    }
    Ok(AggregatorDetails {
        kind: "reddit".into(),
        selftext: None,
        external_url: None,
        points: None,
        comment_count: None,
        comments,
    })
}

fn reddit_rss_comments(bytes: &[u8], limit: usize) -> Result<Vec<AggregatorComment>, String> {
    let feed = feed_rs::parser::parse(bytes).map_err(|error| format!("Reddit returned an invalid feed: {error}"))?;
    Ok(feed
        .entries
        .iter()
        // The first entry (t3_) is the post itself; comments are t1_.
        .filter(|entry| !entry.id.starts_with("t3_"))
        .filter_map(|entry| {
            let author = entry.authors.first()?.name.trim_start_matches("/u/").to_owned();
            let body = clean_html(entry.content.as_ref()?.body.as_deref()?);
            if body.is_empty() || body == "[deleted]" || body == "[removed]" {
                return None;
            }
            Some(AggregatorComment {
                id: entry.id.trim_start_matches("t1_").to_owned(),
                author,
                score: None,
                body,
                depth: 0,
            })
        })
        .take(limit)
        .collect())
}

fn reddit_json_urls(url: &Url, limit: usize) -> Vec<String> {
    let primary = reddit_json_url(url, limit);
    let mut urls = vec![primary.clone()];
    if let Ok(mut old) = Url::parse(&primary) {
        if old.set_host(Some("old.reddit.com")).is_ok() && old.as_str() != primary {
            urls.push(old.to_string());
        }
    }
    urls
}

fn reddit_thread_url(url: &Url, extension: &str) -> Url {
    let mut thread_url = url.clone();
    if let Some(host) = thread_url.host_str() {
        if host == "old.reddit.com" || host == "new.reddit.com" || host == "reddit.com" {
            let _ = thread_url.set_host(Some("www.reddit.com"));
        }
    }
    let path = thread_url.path().trim_end_matches('/');
    let path = path.strip_suffix(".json").or_else(|| path.strip_suffix(".rss")).unwrap_or(path).to_owned();
    thread_url.set_path(&format!("{path}{extension}"));
    thread_url
}

fn reddit_json_url(url: &Url, limit: usize) -> String {
    let mut json_url = reddit_thread_url(url, ".json");
    // raw_json keeps `&`, `<` and `>` literal in comment bodies.
    json_url.set_query(Some(&format!("sort=top&limit={limit}&depth={}&raw_json=1", MAX_COMMENT_DEPTH + 1)));
    json_url.to_string()
}

fn reddit_rss_url(url: &Url, limit: usize) -> String {
    let mut rss_url = reddit_thread_url(url, ".rss");
    rss_url.set_query(Some(&format!("sort=top&limit={limit}")));
    rss_url.to_string()
}

fn reddit_comment(value: &Value, depth: i64) -> Option<AggregatorComment> {
    let data = value.get("data")?;
    let author = data.get("author").and_then(Value::as_str)?;
    if author == "[deleted]" {
        return None;
    }
    let body = data.get("body").and_then(Value::as_str)?;
    if body.is_empty() || body == "[deleted]" || body == "[removed]" {
        return None;
    }
    Some(AggregatorComment {
        id: data.get("id").and_then(Value::as_str).unwrap_or_default().into(),
        author: author.into(),
        score: data.get("score").and_then(Value::as_i64),
        body: body.trim().into(),
        depth,
    })
}

async fn fetch_lobsters(
    client: &Client,
    url: &Url,
    limit: usize,
) -> Result<Option<AggregatorDetails>, String> {
    let mut json_url = url.clone();
    let path = json_url.path().trim_end_matches('/');
    json_url.set_path(&format!("{path}.json"));
    let value = get_json(client, json_url.as_str()).await?;
    let comments = lobsters_comments(value.get("comments").and_then(Value::as_array).map_or(&[], Vec::as_slice), limit);
    Ok(Some(AggregatorDetails {
        kind: "lobsters".into(),
        selftext: value.get("description").and_then(Value::as_str).map(clean_html).filter(|text| !text.is_empty()),
        external_url: http_url(value.get("url").and_then(Value::as_str)),
        points: value.get("score").and_then(Value::as_i64),
        comment_count: value.get("comment_count").and_then(Value::as_i64),
        comments,
    }))
}

/// Lobsters already lists comments in thread order with each one's depth.
fn lobsters_comments(items: &[Value], limit: usize) -> Vec<AggregatorComment> {
    let mut comments = Vec::new();
    let mut top_level = 0;
    // While set, comments deeper than this belong to a dropped comment.
    let mut skip_below: Option<i64> = None;
    for item in items {
        let is_top = item.get("parent_comment").map_or(true, Value::is_null);
        let depth = item
            .get("depth")
            .and_then(Value::as_i64)
            .or_else(|| item.get("indent_level").and_then(Value::as_i64).map(|level| level - 1))
            .unwrap_or(if is_top { 0 } else { 1 })
            .max(0);
        if let Some(limit_depth) = skip_below {
            if depth > limit_depth {
                continue;
            }
            skip_below = None;
        }
        if depth == 0 {
            top_level += 1;
            if top_level > limit {
                break;
            }
        }
        if comments.len() >= MAX_THREAD_COMMENTS {
            break;
        }
        match lobsters_comment(item, depth) {
            Some(comment) if depth <= MAX_COMMENT_DEPTH => comments.push(comment),
            _ => skip_below = Some(depth),
        }
    }
    comments
}

fn lobsters_comment(value: &Value, depth: i64) -> Option<AggregatorComment> {
    let author = value
        .get("commenting_user")
        .and_then(|user| user.as_str().or_else(|| user.get("username").and_then(Value::as_str)))
        .or_else(|| value.get("author").and_then(Value::as_str))?;
    let body = clean_html(value.get("comment").and_then(Value::as_str)?);
    if body.is_empty() {
        return None;
    }
    Some(AggregatorComment {
        id: value
            .get("short_id")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .into(),
        author: author.into(),
        score: value.get("score").and_then(Value::as_i64),
        body,
        depth,
    })
}

fn value_string(value: &Value) -> Option<String> {
    value.as_str().map(str::to_owned).or_else(|| value.as_i64().map(|id| id.to_string()))
}

fn clean_html(value: &str) -> String {
    let mut output = String::with_capacity(value.len());
    let mut in_tag = false;
    let mut tag = String::new();
    for character in value.chars() {
        match character {
            '<' => {
                in_tag = true;
                tag.clear();
            }
            '>' => {
                let normalized = tag.trim().to_ascii_lowercase();
                if normalized.starts_with("p")
                    || normalized.starts_with("/p")
                    || normalized.starts_with("br")
                    || normalized.starts_with("div")
                    || normalized.starts_with("/div")
                {
                    output.push('\n');
                }
                in_tag = false;
            }
            _ if in_tag => tag.push(character),
            _ if !in_tag => output.push(character),
            _ => {}
        }
    }
    output
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&#x27;", "'")
        .replace("&#39;", "'")
        .replace("&quot;", "\"")
        .trim()
        .to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_supported_aggregators_and_ignores_regular_urls() {
        assert_eq!(aggregator_kind(&Url::parse("https://news.ycombinator.com/item?id=1").unwrap()), Some("hacker_news"));
        assert_eq!(aggregator_kind(&Url::parse("https://www.reddit.com/r/rust/comments/abc/post").unwrap()), Some("reddit"));
        assert_eq!(aggregator_kind(&Url::parse("https://lobste.rs/s/abc/title").unwrap()), Some("lobsters"));
        assert_eq!(aggregator_kind(&Url::parse("https://example.com/story").unwrap()), None);
    }

    #[test]
    fn normalizes_comment_text_and_reddit_endpoint() {
        assert_eq!(clean_html("<p>Hello &amp; world</p>"), "Hello & world");
        let url = Url::parse("https://old.reddit.com/r/rust/comments/abc/post/").unwrap();
        assert_eq!(reddit_json_url(&url, 30), "https://www.reddit.com/r/rust/comments/abc/post.json?sort=top&limit=30&depth=5&raw_json=1");
        assert_eq!(
            reddit_json_urls(&url, 10),
            vec![
                "https://www.reddit.com/r/rust/comments/abc/post.json?sort=top&limit=10&depth=5&raw_json=1".to_string(),
                "https://old.reddit.com/r/rust/comments/abc/post.json?sort=top&limit=10&depth=5&raw_json=1".to_string(),
            ]
        );
        assert_eq!(reddit_rss_url(&url, 10), "https://www.reddit.com/r/rust/comments/abc/post.rss?sort=top&limit=10");
    }

    #[test]
    fn counts_nested_hacker_news_comments() {
        let tree = serde_json::json!([
            {"text": "a", "children": [{"text": "b", "children": []}, {"text": null, "children": []}]},
            {"text": "c", "children": []}
        ]);
        assert_eq!(count_hn_comments(tree.as_array().unwrap()), 3);
    }

    fn reddit_node(id: &str, body: &str, replies: Vec<Value>) -> Value {
        let replies = if replies.is_empty() {
            serde_json::json!("")
        } else {
            serde_json::json!({"kind": "Listing", "data": {"children": replies}})
        };
        serde_json::json!({"kind": "t1", "data": {"id": id, "author": format!("u_{id}"), "score": 5, "body": body, "replies": replies}})
    }

    #[test]
    fn flattens_reddit_reply_trees_in_thread_order() {
        let thread = serde_json::json!([
            {"kind": "Listing", "data": {"children": [{"kind": "t3", "data": {"score": 10}}]}},
            {"kind": "Listing", "data": {"children": [
                reddit_node("a", "top", vec![
                    reddit_node("a1", "reply", vec![reddit_node("a11", "deeper", vec![])]),
                    reddit_node("gone", "[removed]", vec![reddit_node("orphan", "lost", vec![])]),
                ]),
                {"kind": "more", "data": {"count": 40}},
                reddit_node("b", "second", vec![]),
            ]}}
        ]);
        let flat: Vec<(String, i64)> = reddit_comments(&thread, 10).into_iter().map(|c| (c.id, c.depth)).collect();
        assert_eq!(
            flat,
            vec![("a".into(), 0), ("a1".into(), 1), ("a11".into(), 2), ("b".into(), 0)]
        );
        assert_eq!(reddit_comments(&thread, 1).len(), 3);
    }

    #[test]
    fn reads_comments_from_reddit_thread_feed() {
        let feed = br#"<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom"><title>post</title><id>x</id><updated>2026-10-14T00:00:00+00:00</updated>
<entry><author><name>/u/op</name></author><content type="html">&lt;div class="md"&gt;&lt;p&gt;the post&lt;/p&gt;&lt;/div&gt;</content><id>t3_abc</id><title>post</title><updated>2026-10-14T00:00:00+00:00</updated></entry>
<entry><author><name>/u/alice</name></author><content type="html">&lt;div class="md"&gt;&lt;p&gt;Tom &amp;amp; Jerry&lt;/p&gt;&lt;/div&gt;</content><id>t1_def</id><title>/u/alice on post</title><updated>2026-10-14T00:00:00+00:00</updated></entry>
</feed>"#;
        let comments = reddit_rss_comments(feed, 10).unwrap();
        assert_eq!(comments.len(), 1);
        assert_eq!(comments[0].id, "def");
        assert_eq!(comments[0].author, "alice");
        assert_eq!(comments[0].body, "Tom & Jerry");
        assert_eq!(comments[0].score, None);
    }

    #[test]
    fn keeps_hacker_news_nesting_and_caps_depth() {
        let mut node = serde_json::json!({"id": 9, "author": "deep", "text": "leaf", "children": []});
        for id in (1..9).rev() {
            node = serde_json::json!({"id": id, "author": "x", "text": "t", "children": [node]});
        }
        let mut out = Vec::new();
        push_hn_thread(&node, 0, &mut out);
        assert_eq!(out.len() as i64, MAX_COMMENT_DEPTH + 1);
        assert_eq!(out.last().unwrap().depth, MAX_COMMENT_DEPTH);
    }

    #[test]
    fn reads_lobsters_depth_and_limits_top_level_threads() {
        let items = serde_json::json!([
            {"short_id": "a", "commenting_user": "ann", "comment": "<p>top</p>", "depth": 0, "parent_comment": null},
            {"short_id": "a1", "commenting_user": "bo", "comment": "<p>reply</p>", "depth": 1, "parent_comment": "a"},
            {"short_id": "b", "commenting_user": "cy", "comment": "", "depth": 0, "parent_comment": null},
            {"short_id": "b1", "commenting_user": "di", "comment": "<p>orphan</p>", "depth": 1, "parent_comment": "b"},
            {"short_id": "c", "commenting_user": "ed", "comment": "<p>third</p>", "depth": 0, "parent_comment": null}
        ]);
        let ids: Vec<String> = lobsters_comments(items.as_array().unwrap(), 10).into_iter().map(|c| c.id).collect();
        assert_eq!(ids, vec!["a", "a1", "c"]);
        assert_eq!(lobsters_comments(items.as_array().unwrap(), 1).len(), 2);
    }
}
