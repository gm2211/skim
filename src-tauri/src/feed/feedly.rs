use crate::db::models::Article;
use chrono::Utc;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

const FEEDLY_API_BASE: &str = "https://cloud.feedly.com/v3";

// ── Existing types (import flow) ────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FeedlySubscription {
    pub id: String,          // feed/http://example.com/feed.xml
    pub title: String,
    #[serde(default)]
    pub website: Option<String>,
    #[serde(default, rename = "iconUrl")]
    pub icon_url: Option<String>,
    #[serde(default)]
    pub categories: Vec<FeedlyCategory>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FeedlyCategory {
    pub id: String,
    pub label: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FeedlyImportResult {
    pub imported: i32,
    pub skipped: i32,
    pub errors: Vec<String>,
}

// ── New types (sync flow) ───────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FeedlyProfile {
    pub id: String,
    #[serde(default)]
    pub email: Option<String>,
    #[serde(default, rename = "fullName")]
    pub full_name: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct FeedlyStreamResponse {
    #[allow(dead_code)]
    pub id: String,
    #[serde(default)]
    pub items: Vec<FeedlyEntry>,
    #[allow(dead_code)]
    #[serde(default)]
    pub continuation: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct FeedlyEntry {
    pub id: String,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub author: Option<String>,
    #[serde(default)]
    pub published: Option<i64>, // millis
    #[serde(default)]
    pub content: Option<FeedlyContent>,
    #[serde(default)]
    pub summary: Option<FeedlyContent>,
    #[serde(default)]
    pub alternate: Option<Vec<FeedlyLink>>,
    #[serde(default)]
    pub unread: bool,
    #[serde(default)]
    pub tags: Option<Vec<FeedlyTag>>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct FeedlyContent {
    #[serde(default)]
    pub content: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct FeedlyLink {
    pub href: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct FeedlyTag {
    pub id: String,
    #[allow(dead_code)]
    #[serde(default)]
    pub label: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FeedlyConnectionStatus {
    pub connected: bool,
    pub email: Option<String>,
    pub full_name: Option<String>,
}

// ── Shared HTTP client ──────────────────────────────────────────────

fn feedly_client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .user_agent("Skim/0.1 RSS Reader")
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| format!("HTTP client error: {}", e))
}

// ── Helpers ─────────────────────────────────────────────────────────

/// Extract the RSS/Atom feed URL from a Feedly subscription ID.
/// Feedly IDs look like "feed/https://example.com/rss.xml"
fn extract_feed_url(feedly_id: &str) -> Option<String> {
    feedly_id.strip_prefix("feed/").map(|s| s.to_string())
}

// ── Subscription / import API ───────────────────────────────────────

/// Fetch the user's subscriptions from Feedly using a developer access token.
pub async fn fetch_subscriptions(token: &str) -> Result<Vec<FeedlySubscription>, String> {
    let client = feedly_client()?;

    let response = client
        .get(format!("{}/subscriptions", FEEDLY_API_BASE))
        .header("Authorization", format!("Bearer {}", token))
        .send()
        .await
        .map_err(|e| format!("Failed to contact Feedly: {}", e))?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        return Err(format!("Feedly API error ({}): {}", status, body));
    }

    response
        .json::<Vec<FeedlySubscription>>()
        .await
        .map_err(|e| format!("Failed to parse Feedly response: {}", e))
}

/// Import Feedly subscriptions as local feeds. Returns each subscription
/// with its extracted feed URL.
pub fn subscriptions_to_feeds(
    subs: &[FeedlySubscription],
) -> Vec<(crate::db::models::Feed, String)> {
    let now = chrono::Utc::now().timestamp();
    subs.iter()
        .filter_map(|sub| {
            let feed_url = extract_feed_url(&sub.id)?;
            let feed = crate::db::models::Feed {
                id: uuid::Uuid::new_v4().to_string(),
                title: sub.title.clone(),
                url: feed_url.clone(),
                site_url: sub.website.clone(),
                description: None,
                icon_url: sub.icon_url.clone(),
                feedly_id: Some(sub.id.clone()),
                created_at: now,
                updated_at: now,
                last_fetched_at: None,
                folder_id: None,
                opml_category: sub.categories.first().map(|c| c.label.clone()),
            };
            Some((feed, feed_url))
        })
        .collect()
}

// ── Profile / token verification ────────────────────────────────────

/// Verify a Feedly access token and return the user profile.
pub async fn verify_token(token: &str) -> Result<FeedlyProfile, String> {
    let client = feedly_client()?;

    let response = client
        .get(format!("{}/profile", FEEDLY_API_BASE))
        .header("Authorization", format!("Bearer {}", token))
        .send()
        .await
        .map_err(|e| format!("Failed to contact Feedly: {}", e))?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        return Err(format!("Feedly authentication failed ({}): {}", status, body));
    }

    response
        .json::<FeedlyProfile>()
        .await
        .map_err(|e| format!("Failed to parse Feedly profile: {}", e))
}

// ── Stream contents (article fetching) ──────────────────────────────

/// Fetch articles for a feed from Feedly's streams API.
///
/// - `stream_id`: the Feedly feed ID (e.g. "feed/https://example.com/rss")
/// - `newer_than`: optional Unix timestamp (seconds) — only return entries newer than this
/// - `count`: max entries to return (Feedly default 20, max 1000)
pub async fn fetch_stream_contents(
    token: &str,
    stream_id: &str,
    newer_than: Option<i64>,
    count: u32,
) -> Result<FeedlyStreamResponse, String> {
    let client = feedly_client()?;

    let mut url = format!(
        "{}/streams/contents?streamId={}&count={}",
        FEEDLY_API_BASE,
        urlencoding::encode(stream_id),
        count,
    );

    if let Some(ts) = newer_than {
        // Feedly uses milliseconds
        url.push_str(&format!("&newerThan={}", ts * 1000));
    }

    let response = client
        .get(&url)
        .header("Authorization", format!("Bearer {}", token))
        .send()
        .await
        .map_err(|e| format!("Failed to fetch Feedly stream: {}", e))?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        return Err(format!("Feedly stream error ({}): {}", status, body));
    }

    response
        .json::<FeedlyStreamResponse>()
        .await
        .map_err(|e| format!("Failed to parse Feedly stream: {}", e))
}

/// Convert Feedly entries to local Article structs.
pub fn feedly_entries_to_articles(entries: &[FeedlyEntry], feed_id: &str) -> Vec<Article> {
    let now = Utc::now().timestamp();

    entries
        .iter()
        .map(|entry| {
            let content_html = entry
                .content
                .as_ref()
                .and_then(|c| c.content.clone())
                .or_else(|| entry.summary.as_ref().and_then(|s| s.content.clone()));

            let content_text = content_html.as_ref().map(|html| {
                html2text::from_read(html.as_bytes(), 80)
            });

            let article_url = entry
                .alternate
                .as_ref()
                .and_then(|links| links.first().map(|l| l.href.clone()));

            // Feedly timestamps are in milliseconds
            let published_at = entry.published.map(|ms| ms / 1000);

            let is_starred = entry
                .tags
                .as_ref()
                .map(|tags| tags.iter().any(|t| t.id.contains("global.saved")))
                .unwrap_or(false);

            Article {
                id: Uuid::new_v4().to_string(),
                feed_id: feed_id.to_string(),
                title: entry
                    .title
                    .clone()
                    .unwrap_or_else(|| "Untitled".to_string()),
                url: article_url,
                author: entry.author.clone(),
                content_html,
                content_text,
                published_at,
                fetched_at: now,
                is_read: !entry.unread,
                is_starred,
                feedly_entry_id: Some(entry.id.clone()),
            }
        })
        .collect()
}

// ── Markers API (read/unread state) ─────────────────────────────────

/// Mark Feedly entries as read.
pub async fn mark_entries_read(token: &str, entry_ids: Vec<String>) -> Result<(), String> {
    if entry_ids.is_empty() {
        return Ok(());
    }
    let client = feedly_client()?;

    let body = serde_json::json!({
        "action": "markAsRead",
        "type": "entries",
        "entryIds": entry_ids,
    });

    let response = client
        .post(format!("{}/markers", FEEDLY_API_BASE))
        .header("Authorization", format!("Bearer {}", token))
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("Failed to mark entries read: {}", e))?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        return Err(format!("Feedly markers error ({}): {}", status, body));
    }

    Ok(())
}

/// Mark Feedly entries as unread (keep unread).
pub async fn mark_entries_unread(token: &str, entry_ids: Vec<String>) -> Result<(), String> {
    if entry_ids.is_empty() {
        return Ok(());
    }
    let client = feedly_client()?;

    let body = serde_json::json!({
        "action": "keepUnread",
        "type": "entries",
        "entryIds": entry_ids,
    });

    let response = client
        .post(format!("{}/markers", FEEDLY_API_BASE))
        .header("Authorization", format!("Bearer {}", token))
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("Failed to mark entries unread: {}", e))?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        return Err(format!("Feedly markers error ({}): {}", status, body));
    }

    Ok(())
}

/// Mark an entire Feedly feed as read.
pub async fn mark_feed_read(token: &str, feedly_feed_id: &str, as_of_millis: i64) -> Result<(), String> {
    let client = feedly_client()?;

    let body = serde_json::json!({
        "action": "markAsRead",
        "type": "feeds",
        "feedIds": [feedly_feed_id],
        "asOf": as_of_millis,
    });

    let response = client
        .post(format!("{}/markers", FEEDLY_API_BASE))
        .header("Authorization", format!("Bearer {}", token))
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("Failed to mark feed read: {}", e))?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        return Err(format!("Feedly markers error ({}): {}", status, body));
    }

    Ok(())
}

// ── Tags API (star/save) ────────────────────────────────────────────

/// Save (star) an entry in Feedly.
pub async fn save_entry(token: &str, user_id: &str, entry_ids: Vec<String>) -> Result<(), String> {
    if entry_ids.is_empty() {
        return Ok(());
    }
    let client = feedly_client()?;

    let tag_id = format!("user/{}/tag/global.saved", user_id);

    let body = serde_json::json!({
        "entryIds": entry_ids,
    });

    let response = client
        .put(format!("{}/tags/{}", FEEDLY_API_BASE, urlencoding::encode(&tag_id)))
        .header("Authorization", format!("Bearer {}", token))
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("Failed to save entry: {}", e))?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        return Err(format!("Feedly tags error ({}): {}", status, body));
    }

    Ok(())
}

/// Unsave (unstar) an entry in Feedly.
pub async fn unsave_entry(token: &str, user_id: &str, entry_id: &str) -> Result<(), String> {
    let client = feedly_client()?;

    let tag_id = format!("user/{}/tag/global.saved", user_id);

    let response = client
        .delete(format!(
            "{}/tags/{}/{}",
            FEEDLY_API_BASE,
            urlencoding::encode(&tag_id),
            urlencoding::encode(entry_id),
        ))
        .header("Authorization", format!("Bearer {}", token))
        .send()
        .await
        .map_err(|e| format!("Failed to unsave entry: {}", e))?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        return Err(format!("Feedly tags error ({}): {}", status, body));
    }

    Ok(())
}
