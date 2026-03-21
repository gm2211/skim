use crate::db::models::{Article, Feed};
use chrono::Utc;
use feed_rs::parser;
use uuid::Uuid;

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

    let feed = Feed {
        id: feed_id.clone(),
        title,
        url: feed_url.to_string(),
        site_url,
        description,
        icon_url: parsed.icon.map(|i| i.uri),
        feedly_id: None,
        created_at: now,
        updated_at: now,
        last_fetched_at: Some(now),
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
            }
        })
        .collect();

    Ok((feed, articles))
}
