use crate::db::models::ArticleFilter;
use crate::db::queries;
use crate::db::Database;
use crate::feed::feedly;
use regex::Regex;
use serde::Serialize;
use serde_json::Value;
use tauri::State;
use url::Url;

/// Read the Feedly token and user ID from settings, if configured.
fn get_feedly_context(db: &Database) -> Option<(String, String)> {
    let conn = db.conn.lock().ok()?;
    let token = queries::get_setting(&conn, "feedly_token").ok()??;
    let user_id = queries::get_setting(&conn, "feedly_user_id").ok()??;
    Some((token, user_id))
}

#[tauri::command]
pub async fn get_articles(
    db: State<'_, Database>,
    filter: ArticleFilter,
) -> Result<Vec<crate::db::models::ArticleWithFeed>, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::get_articles(&conn, &filter).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn count_articles(db: State<'_, Database>, filter: ArticleFilter) -> Result<i64, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::count_articles(&conn, &filter).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn get_article(
    db: State<'_, Database>,
    article_id: String,
) -> Result<crate::db::models::ArticleWithFeed, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::get_article_by_id(&conn, &article_id)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "Article not found".to_string())
}

#[tauri::command]
pub async fn mark_articles_read(
    db: State<'_, Database>,
    article_ids: Vec<String>,
) -> Result<(), String> {
    let feedly_entry_ids = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        queries::mark_articles_read(&conn, &article_ids).map_err(|e| e.to_string())?;
        queries::get_feedly_entry_ids(&conn, &article_ids).unwrap_or_default()
    };

    if !feedly_entry_ids.is_empty() {
        if let Some((token, _user_id)) = get_feedly_context(&db) {
            let entry_ids: Vec<String> = feedly_entry_ids.into_iter().map(|(_, eid)| eid).collect();
            tokio::spawn(async move {
                if let Err(e) = feedly::mark_entries_read(&token, entry_ids).await {
                    log::warn!("Failed to sync read state to Feedly: {}", e);
                }
            });
        }
    }

    Ok(())
}

#[tauri::command]
pub async fn mark_articles_unread(
    db: State<'_, Database>,
    article_ids: Vec<String>,
) -> Result<(), String> {
    let feedly_entry_ids = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        queries::mark_articles_unread(&conn, &article_ids).map_err(|e| e.to_string())?;
        queries::get_feedly_entry_ids(&conn, &article_ids).unwrap_or_default()
    };

    if !feedly_entry_ids.is_empty() {
        if let Some((token, _user_id)) = get_feedly_context(&db) {
            let entry_ids: Vec<String> = feedly_entry_ids.into_iter().map(|(_, eid)| eid).collect();
            tokio::spawn(async move {
                if let Err(e) = feedly::mark_entries_unread(&token, entry_ids).await {
                    log::warn!("Failed to sync unread state to Feedly: {}", e);
                }
            });
        }
    }

    Ok(())
}

#[tauri::command]
pub async fn mark_all_read(db: State<'_, Database>, feed_id: Option<String>) -> Result<(), String> {
    // Gather Feedly context before applying local changes
    let feedly_sync_info = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        if let Some(ref fid) = feed_id {
            // Check if this feed has a feedly_id
            queries::get_feed_by_id(&conn, fid)
                .ok()
                .flatten()
                .and_then(|f| f.feedly_id)
                .map(|feedly_id| (feedly_id, fid.clone()))
        } else {
            None
        }
    };

    {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        queries::mark_all_read(&conn, feed_id.as_deref()).map_err(|e| e.to_string())?;
    }

    // Push to Feedly if applicable
    if let Some((feedly_feed_id, _)) = feedly_sync_info {
        if let Some((token, _user_id)) = get_feedly_context(&db) {
            let now_millis = chrono::Utc::now().timestamp_millis();
            tokio::spawn(async move {
                if let Err(e) = feedly::mark_feed_read(&token, &feedly_feed_id, now_millis).await {
                    log::warn!("Failed to sync mark-all-read to Feedly: {}", e);
                }
            });
        }
    }

    Ok(())
}

#[tauri::command]
pub async fn toggle_read(db: State<'_, Database>, article_id: String) -> Result<bool, String> {
    let (new_is_read, feedly_entry_id) = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        let new_is_read = queries::toggle_read(&conn, &article_id).map_err(|e| e.to_string())?;
        let entry_ids =
            queries::get_feedly_entry_ids(&conn, &[article_id.clone()]).unwrap_or_default();
        let feedly_entry_id = entry_ids.into_iter().next().map(|(_, eid)| eid);
        (new_is_read, feedly_entry_id)
    };

    if let Some(entry_id) = feedly_entry_id {
        if let Some((token, _user_id)) = get_feedly_context(&db) {
            tokio::spawn(async move {
                let result = if new_is_read {
                    feedly::mark_entries_read(&token, vec![entry_id]).await
                } else {
                    feedly::mark_entries_unread(&token, vec![entry_id]).await
                };
                if let Err(e) = result {
                    log::warn!("Failed to sync read state to Feedly: {}", e);
                }
            });
        }
    }

    Ok(new_is_read)
}

#[derive(Debug, Serialize)]
pub struct FullArticleContent {
    pub html: String,
    pub raw_html: String,
}

/// Rewrite URLs to static/readable versions when possible. Some popular sites
/// ship hydrated shells that replay poorly inside an embedded srcDoc iframe.
fn rewrite_for_static(url: &str) -> String {
    if let Ok(parsed) = url::Url::parse(url) {
        if let Some(host) = parsed.host_str() {
            let host_lower = host.to_lowercase();
            if host_lower == "www.reddit.com"
                || host_lower == "reddit.com"
                || host_lower == "new.reddit.com"
            {
                let mut new_url = parsed.clone();
                let _ = new_url.set_host(Some("old.reddit.com"));
                return new_url.to_string();
            }

            if (host_lower == "github.com" || host_lower == "www.github.com")
                && parsed.path().to_lowercase().ends_with(".ipynb")
                && parsed.path().contains("/blob/")
            {
                return format!(
                    "https://nbviewer.org/github/{}",
                    parsed.path().trim_start_matches('/')
                );
            }
        }
    }
    url.to_string()
}

fn is_hacker_news_host(host: &str) -> bool {
    host == "news.ycombinator.com" || host.ends_with(".ycombinator.com")
}

fn is_reddit_host(host: &str) -> bool {
    matches!(
        host,
        "reddit.com" | "www.reddit.com" | "old.reddit.com" | "new.reddit.com"
    ) || host.ends_with(".reddit.com")
        || host == "redd.it"
}

fn is_external_to_host_family(candidate: &Url, original: &Url) -> bool {
    let Some(candidate_host) = candidate.host_str().map(str::to_lowercase) else {
        return false;
    };
    let Some(original_host) = original.host_str().map(str::to_lowercase) else {
        return true;
    };

    if is_hacker_news_host(&original_host) {
        return !is_hacker_news_host(&candidate_host);
    }
    if is_reddit_host(&original_host) {
        return !is_reddit_host(&candidate_host);
    }

    candidate_host != original_host
}

fn extract_hacker_news_external_url(html: &str, base: &Url) -> Option<String> {
    let patterns = [
        r#"(?is)<span[^>]*class=["'][^"']*\btitleline\b[^"']*["'][^>]*>\s*<a[^>]*href=["']([^"']+)["']"#,
        r#"(?is)<a[^>]*class=["'][^"']*\bstorylink\b[^"']*["'][^>]*href=["']([^"']+)["']"#,
        r#"(?is)<a[^>]*href=["']([^"']+)["'][^>]*class=["'][^"']*\bstorylink\b[^"']*["']"#,
    ];

    for pattern in patterns {
        let Ok(regex) = Regex::new(pattern) else {
            continue;
        };
        for captures in regex.captures_iter(html) {
            let Some(href) = captures.get(1).map(|m| m.as_str()) else {
                continue;
            };
            let Ok(url) = base.join(href) else { continue };
            if is_external_to_host_family(&url, base) {
                return Some(url.to_string());
            }
        }
    }

    None
}

fn reddit_json_url(url: &Url) -> String {
    let mut json_url = url.clone();
    if let Some(host) = json_url.host_str() {
        if host == "old.reddit.com" {
            let _ = json_url.set_host(Some("www.reddit.com"));
        }
    }
    if !json_url.path().ends_with(".json") {
        let path = json_url.path().trim_end_matches('/');
        json_url.set_path(&format!("{path}.json"));
    }
    json_url.to_string()
}

fn extract_reddit_external_url_from_json(value: &Value) -> Option<String> {
    fn walk(value: &Value) -> Option<String> {
        match value {
            Value::Object(map) => {
                if let Some(data) = map.get("data").and_then(Value::as_object) {
                    let is_self = data
                        .get("is_self")
                        .and_then(Value::as_bool)
                        .unwrap_or(false);
                    let candidate = data
                        .get("url_overridden_by_dest")
                        .or_else(|| data.get("url"))
                        .and_then(Value::as_str);
                    if !is_self {
                        if let Some(url) = candidate {
                            if Url::parse(url)
                                .ok()
                                .and_then(|u| {
                                    u.host_str()
                                        .map(str::to_lowercase)
                                        .filter(|host| !is_reddit_host(host))
                                        .map(|_| u.to_string())
                                })
                                .is_some()
                            {
                                return Some(url.to_string());
                            }
                        }
                    }
                }
                map.values().find_map(walk)
            }
            Value::Array(items) => items.iter().find_map(walk),
            _ => None,
        }
    }

    walk(value)
}

fn extract_reddit_external_url_from_html(html: &str, base: &Url) -> Option<String> {
    let Ok(regex) = Regex::new(r#"(?is)<a[^>]+href=["']([^"']+)["'][^>]*>"#) else {
        return None;
    };
    for captures in regex.captures_iter(html) {
        let Some(href) = captures.get(1).map(|m| m.as_str()) else {
            continue;
        };
        let Ok(url) = base.join(href) else { continue };
        if is_external_to_host_family(&url, base) {
            return Some(url.to_string());
        }
    }
    None
}

async fn resolve_aggregator_target(client: &reqwest::Client, url: &str) -> Option<String> {
    let parsed = Url::parse(url).ok()?;
    let host = parsed.host_str()?.to_lowercase();

    if is_hacker_news_host(&host) {
        let html = client
            .get(parsed.as_str())
            .send()
            .await
            .ok()?
            .text()
            .await
            .ok()?;
        return extract_hacker_news_external_url(&html, &parsed);
    }

    if is_reddit_host(&host) {
        let json_endpoint = reddit_json_url(&parsed);
        if let Ok(response) = client.get(&json_endpoint).send().await {
            if let Ok(value) = response.json::<Value>().await {
                if let Some(external) = extract_reddit_external_url_from_json(&value) {
                    return Some(external);
                }
            }
        }

        let html = client
            .get(parsed.as_str())
            .send()
            .await
            .ok()?
            .text()
            .await
            .ok()?;
        return extract_reddit_external_url_from_html(&html, &parsed);
    }

    None
}

#[tauri::command]
pub async fn fetch_full_article(url: String) -> Result<FullArticleContent, String> {
    let client = reqwest::Client::builder()
        // Use a real browser UA — some sites serve blank shells to unknown UAs
        .user_agent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15")
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| format!("Failed to create HTTP client: {}", e))?;
    let target_url = resolve_aggregator_target(&client, &url)
        .await
        .unwrap_or(url);
    let effective_url = rewrite_for_static(&target_url);

    let response = client
        .get(&effective_url)
        .send()
        .await
        .map_err(|e| format!("Failed to fetch article: {}", e))?;

    let html = response
        .text()
        .await
        .map_err(|e| format!("Failed to read response: {}", e))?;

    // Inject <base href="..."> so relative URLs (images, stylesheets) resolve
    // against the original site if anything ends up consuming raw_html.
    let base_tag = format!("<base href=\"{}\">", effective_url.replace('"', "&quot;"));
    let raw_html = if let Some(head_end) = html.to_lowercase().find("<head") {
        if let Some(tag_close) = html[head_end..].find('>') {
            let insert_at = head_end + tag_close + 1;
            format!("{}{}{}", &html[..insert_at], base_tag, &html[insert_at..])
        } else {
            html.clone()
        }
    } else {
        html.clone()
    };

    // Many SPAs (Next.js, etc.) ship a <script id="__NEXT_DATA__"> JSON blob
    // with the article body — readability can't see it because the page DOM
    // hasn't been hydrated. Try to pull a usable body string out of common
    // shapes first; fall back to dom_smoothie for traditional pages.
    let nextjs_extract = extract_from_next_data(&html);

    let cleaned = if let Some(body) = nextjs_extract {
        plain_to_html(&body)
    } else {
        match dom_smoothie::Readability::new(
            html.as_str(),
            Some(&effective_url),
            Some(dom_smoothie::Config::default()),
        ) {
            Ok(mut r) => match r.parse() {
                Ok(article) => article.content.to_string(),
                Err(_) => String::new(),
            },
            Err(_) => String::new(),
        }
    };

    Ok(FullArticleContent {
        html: cleaned,
        raw_html,
    })
}

// Walk common Next.js / framework JSON shapes to find a long article-body
// string. Returns Some(body) only if the candidate is at least 500 chars,
// which keeps us from picking up excerpts or metadata blurbs.
fn extract_from_next_data(html: &str) -> Option<String> {
    let needle = r#"id="__NEXT_DATA__""#;
    let i = html.find(needle)?;
    let start = html[i..].find('>')? + i + 1;
    let end = html[start..].find("</script>")? + start;
    let blob = &html[start..end];
    let json: serde_json::Value = serde_json::from_str(blob).ok()?;

    // Common keys that hold the actual article content as a string.
    const BODY_KEYS: &[&str] = &[
        "articleBody",
        "body",
        "content",
        "html",
        "markup",
        "rawBody",
        "post_body",
        "story_body",
    ];

    fn walk(v: &serde_json::Value, out: &mut Option<String>) {
        if out.is_some() {
            return;
        }
        match v {
            serde_json::Value::Object(map) => {
                for (k, vv) in map {
                    if BODY_KEYS.contains(&k.as_str()) {
                        if let Some(s) = vv.as_str() {
                            if s.len() >= 500 {
                                *out = Some(s.to_string());
                                return;
                            }
                        }
                    }
                    walk(vv, out);
                    if out.is_some() {
                        return;
                    }
                }
            }
            serde_json::Value::Array(arr) => {
                for vv in arr {
                    walk(vv, out);
                    if out.is_some() {
                        return;
                    }
                }
            }
            _ => {}
        }
    }

    let mut found = None;
    walk(&json, &mut found);
    found
}

// Convert a plain-text (or lightly-marked) article body to renderable HTML:
// split on blank lines for paragraphs, auto-link bare URLs, escape HTML.
fn plain_to_html(text: &str) -> String {
    // If the body already looks like HTML, hand it back unchanged.
    if text.contains("<p") || text.contains("<div") || text.contains("<h2") {
        return text.to_string();
    }
    let mut out = String::with_capacity(text.len() + 128);
    let url_re = regex::Regex::new(r"https?://[^\s<>\)\]]+").unwrap();
    for para in text.split("\n\n") {
        let p = para.trim();
        if p.is_empty() {
            continue;
        }
        let escaped = p
            .replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('>', "&gt;");
        let linked = url_re.replace_all(&escaped, |caps: &regex::Captures| {
            let u = &caps[0];
            format!(
                r#"<a href="{}" target="_blank" rel="noreferrer">{}</a>"#,
                u, u
            )
        });
        out.push_str("<p>");
        out.push_str(&linked.replace('\n', "<br/>"));
        out.push_str("</p>\n");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::{
        extract_hacker_news_external_url, extract_reddit_external_url_from_json, reddit_json_url,
        rewrite_for_static,
    };
    use serde_json::json;
    use url::Url;

    #[test]
    fn rewrites_reddit_to_old_reddit() {
        assert_eq!(
            rewrite_for_static("https://www.reddit.com/r/rust/comments/abc/example/"),
            "https://old.reddit.com/r/rust/comments/abc/example/"
        );
    }

    #[test]
    fn rewrites_github_notebooks_to_nbviewer() {
        assert_eq!(
            rewrite_for_static(
                "https://github.com/norvig/pytudes/blob/main/ipynb/xkcd-Name-Dominoes.ipynb"
            ),
            "https://nbviewer.org/github/norvig/pytudes/blob/main/ipynb/xkcd-Name-Dominoes.ipynb"
        );
    }

    #[test]
    fn leaves_non_notebook_github_urls_unchanged() {
        assert_eq!(
            rewrite_for_static("https://github.com/norvig/pytudes/blob/main/README.md"),
            "https://github.com/norvig/pytudes/blob/main/README.md"
        );
    }

    #[test]
    fn extracts_hacker_news_story_target() {
        let base = Url::parse("https://news.ycombinator.com/item?id=123").unwrap();
        let html =
            r#"<span class="titleline"><a href="https://example.com/story">Story</a></span>"#;
        assert_eq!(
            extract_hacker_news_external_url(html, &base),
            Some("https://example.com/story".to_string())
        );
    }

    #[test]
    fn extracts_reddit_link_post_target_from_json() {
        let value = json!([
            {
                "data": {
                    "children": [
                        {
                            "data": {
                                "is_self": false,
                                "url_overridden_by_dest": "https://example.com/article"
                            }
                        }
                    ]
                }
            }
        ]);
        assert_eq!(
            extract_reddit_external_url_from_json(&value),
            Some("https://example.com/article".to_string())
        );
    }

    #[test]
    fn builds_reddit_json_url() {
        let url =
            Url::parse("https://old.reddit.com/r/rust/comments/abc/example/?sort=top").unwrap();
        assert_eq!(
            reddit_json_url(&url),
            "https://www.reddit.com/r/rust/comments/abc/example.json?sort=top"
        );
    }
}

#[tauri::command]
pub async fn toggle_star(db: State<'_, Database>, article_id: String) -> Result<bool, String> {
    let (new_is_starred, feedly_entry_id) = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        let new_is_starred = queries::toggle_star(&conn, &article_id).map_err(|e| e.to_string())?;
        let entry_ids =
            queries::get_feedly_entry_ids(&conn, &[article_id.clone()]).unwrap_or_default();
        let feedly_entry_id = entry_ids.into_iter().next().map(|(_, eid)| eid);
        (new_is_starred, feedly_entry_id)
    };

    if let Some(entry_id) = feedly_entry_id {
        if let Some((token, user_id)) = get_feedly_context(&db) {
            tokio::spawn(async move {
                let result = if new_is_starred {
                    feedly::save_entry(&token, &user_id, vec![entry_id]).await
                } else {
                    feedly::unsave_entry(&token, &user_id, &entry_id).await
                };
                if let Err(e) = result {
                    log::warn!("Failed to sync star state to Feedly: {}", e);
                }
            });
        }
    }

    Ok(new_is_starred)
}
