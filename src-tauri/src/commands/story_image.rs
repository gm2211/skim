//! The picture a Today story is set with. Only images the reports themselves
//! publish are used: the linked page's share image, then the first sizable
//! image in the reader copy, then one in the feed item. Offline-safe: it reads
//! what the reader and the summary pass already cached and never fetches.

use crate::db::{queries, Database};
use regex::Regex;
use std::sync::OnceLock;
use tauri::State;

/// The first image any of `article_ids` publishes, in the order given.
#[tauri::command]
pub fn get_today_story_image(db: State<'_, Database>, article_ids: Vec<String>) -> Result<Option<String>, String> {
    let conn = db.conn.lock().map_err(|error| error.to_string())?;
    for article_id in article_ids.iter().take(8) {
        let article = queries::get_article_by_id(&conn, article_id).map_err(|error| error.to_string())?;
        let page_url = queries::get_reader_cache_url(&conn, article_id).ok().flatten()
            .or_else(|| article.as_ref().and_then(|article| article.article.url.clone()));
        if let Some((html, raw_html)) = queries::get_reader_cache(&conn, article_id).ok().flatten() {
            if let Some(image) = share_image(&raw_html, page_url.as_deref())
                .or_else(|| first_content_image(&html, page_url.as_deref())) {
                return Ok(Some(image));
            }
        }
        if let Some(article) = article {
            let feed_html = article.article.content_html.as_deref().unwrap_or_default();
            if let Some(image) = first_content_image(feed_html, article.article.url.as_deref()) {
                return Ok(Some(image));
            }
        }
    }
    Ok(None)
}

fn meta_tag() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(?is)<meta\b[^>]*>").unwrap())
}

fn img_tag() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(?is)<img\b[^>]*>").unwrap())
}

fn attribute(tag: &str, name: &str) -> Option<String> {
    let re = Regex::new(&format!(r#"(?is)\s{name}\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#)).ok()?;
    let captures = re.captures(tag)?;
    let value = captures.get(1).or_else(|| captures.get(2)).or_else(|| captures.get(3))?.as_str();
    Some(value.replace("&amp;", "&").trim().to_string())
}

/// The page's Open Graph or Twitter card image.
fn share_image(page_html: &str, base: Option<&str>) -> Option<String> {
    for wanted in ["og:image:secure_url", "og:image", "og:image:url", "twitter:image", "twitter:image:src"] {
        for tag in meta_tag().find_iter(page_html).map(|found| found.as_str()) {
            let key = attribute(tag, "property").or_else(|| attribute(tag, "name"));
            if key.is_some_and(|key| key.eq_ignore_ascii_case(wanted)) {
                if let Some(url) = attribute(tag, "content").and_then(|src| absolute_image(&src, base)) {
                    return Some(url);
                }
            }
        }
    }
    None
}

/// The first image in article HTML that is not a tracking pixel, badge or icon.
fn first_content_image(html: &str, base: Option<&str>) -> Option<String> {
    img_tag().find_iter(html).map(|found| found.as_str()).find_map(|tag| {
        let src = attribute(tag, "src")?;
        let small = |name| attribute(tag, name).and_then(|value| value.parse::<u32>().ok()).is_some_and(|size| size < 100);
        if small("width") || small("height") { return None; }
        absolute_image(&src, base)
    })
}

fn absolute_image(src: &str, base: Option<&str>) -> Option<String> {
    let lowered = src.to_ascii_lowercase();
    if src.is_empty() || ["feedburner", "pixel", "badge", "favicon", "logo", "avatar", "gravatar", "spacer", ".svg"]
        .iter().any(|noise| lowered.contains(noise)) {
        return None;
    }
    let url = match base.and_then(|base| url::Url::parse(base).ok()) {
        Some(base) => base.join(src).ok()?,
        None => url::Url::parse(src).ok()?,
    };
    matches!(url.scheme(), "http" | "https").then(|| url.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn share_image_wins_and_resolves_against_the_page() {
        let page = r#"<html><head><meta content="/img/lead.jpg" property="og:image"><meta name='twitter:image' content='https://cdn.example.com/t.jpg'></head></html>"#;
        assert_eq!(share_image(page, Some("https://example.com/post/1")).as_deref(), Some("https://example.com/img/lead.jpg"));
        let twitter_only = r#"<meta name="twitter:image" content="https://cdn.example.com/t.jpg?a=1&amp;b=2">"#;
        assert_eq!(share_image(twitter_only, None).as_deref(), Some("https://cdn.example.com/t.jpg?a=1&b=2"));
    }

    #[test]
    fn content_images_skip_pixels_icons_and_unsafe_schemes() {
        let html = r#"<img src="https://feeds.feedburner.com/x.gif"><img src="/a.png" width="1" height="1"><img src="data:image/png;base64,xx"><img src="https://example.com/site-logo.png"><img src="photo.jpg" width="800">"#;
        assert_eq!(first_content_image(html, Some("https://example.com/story/")).as_deref(), Some("https://example.com/story/photo.jpg"));
        assert_eq!(first_content_image(r#"<a href="https://news.ycombinator.com/item?id=1">Comments</a>"#, None), None);
    }
}
