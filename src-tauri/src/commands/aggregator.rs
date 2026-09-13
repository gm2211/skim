use reqwest::Client;
use serde::Serialize;
use serde_json::Value;
use tauri::command;
use url::Url;

const DEFAULT_COMMENT_LIMIT: usize = 10;

#[derive(Debug, Clone, Serialize)]
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
    pub comments: Vec<AggregatorComment>,
}

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
    let limit = limit.unwrap_or(DEFAULT_COMMENT_LIMIT).clamp(1, 25);
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
    let comments = value
        .get("children")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .take(limit)
        .filter_map(hn_comment)
        .collect();
    Ok(Some(AggregatorDetails {
        kind: "hacker_news".into(),
        selftext: value.get("text").and_then(Value::as_str).map(clean_html).filter(|text| !text.is_empty()),
        external_url: http_url(value.get("url").and_then(Value::as_str)),
        comments,
    }))
}

fn hn_comment(value: &Value) -> Option<AggregatorComment> {
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
        depth: 0,
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
    let json_url = reddit_json_url(url);
    let value = get_json(client, &json_url).await?;
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
    let comments = value
        .as_array()
        .and_then(|root| root.get(1))
        .and_then(|listing| listing.get("data"))
        .and_then(|data| data.get("children"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .take(limit)
        .filter_map(reddit_comment)
        .collect();
    Ok(Some(AggregatorDetails {
        kind: "reddit".into(),
        selftext,
        external_url,
        comments,
    }))
}

fn reddit_json_url(url: &Url) -> String {
    let mut json_url = url.clone();
    if let Some(host) = json_url.host_str() {
        if host == "old.reddit.com" || host == "new.reddit.com" || host == "reddit.com" {
            let _ = json_url.set_host(Some("www.reddit.com"));
        }
    }
    let path = json_url.path().trim_end_matches('/');
    if !path.ends_with(".json") {
        json_url.set_path(&format!("{path}.json"));
    }
    json_url.set_query(Some("sort=top&limit=10&depth=1"));
    json_url.to_string()
}

fn reddit_comment(value: &Value) -> Option<AggregatorComment> {
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
        depth: 0,
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
    let comments = value
        .get("comments")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|comment| comment.get("parent_comment").map_or(true, Value::is_null))
        .take(limit)
        .filter_map(lobsters_comment)
        .collect();
    Ok(Some(AggregatorDetails {
        kind: "lobsters".into(),
        selftext: value.get("description").and_then(Value::as_str).map(clean_html).filter(|text| !text.is_empty()),
        external_url: http_url(value.get("url").and_then(Value::as_str)),
        comments,
    }))
}

fn lobsters_comment(value: &Value) -> Option<AggregatorComment> {
    let author = value
        .get("commenting_user")
        .and_then(|user| user.get("username"))
        .and_then(Value::as_str)
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
        depth: 0,
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
        assert_eq!(reddit_json_url(&url), "https://www.reddit.com/r/rust/comments/abc/post.json?sort=top&limit=10&depth=1");
    }
}
