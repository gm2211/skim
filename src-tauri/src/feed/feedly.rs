use serde::{Deserialize, Serialize};

const FEEDLY_API_BASE: &str = "https://cloud.feedly.com/v3";

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

/// Extract the RSS/Atom feed URL from a Feedly subscription ID.
/// Feedly IDs look like "feed/https://example.com/rss.xml"
fn extract_feed_url(feedly_id: &str) -> Option<String> {
    feedly_id.strip_prefix("feed/").map(|s| s.to_string())
}

/// Fetch the user's subscriptions from Feedly using a developer access token.
pub async fn fetch_subscriptions(token: &str) -> Result<Vec<FeedlySubscription>, String> {
    let client = reqwest::Client::builder()
        .user_agent("Skim/0.1 RSS Reader")
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| format!("HTTP client error: {}", e))?;

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
            };
            Some((feed, feed_url))
        })
        .collect()
}
