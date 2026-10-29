//! Major newspapers: one-tap follows for their official RSS sections, and an
//! in-app sign-in so a subscriber's full articles load in the reader.
//!
//! Signing in opens the paper's own login page in a Skim window. That window
//! shares the app's WebKit cookie store, so once the reader has signed in the
//! paper's cookies are read back from it and sent, only to that paper's
//! domains, when the reader fetches one of its articles.

use crate::db::queries;
use crate::db::Database;
use crate::feed::discovery::{self, CatalogFeed, DiscoveredFeed};
use crate::AppHandle;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{OnceLock, RwLock};
use tauri::{Emitter, Manager, State};

const NEWSPAPERS_JSON: &str = include_str!("../../../shared/newspapers.json");
/// Window label of the sign-in browser. One paper signs in at a time.
const SIGN_IN_WINDOW: &str = "newspaper-sign-in";
/// Tells the frontend to reload sign-in state after the sign-in window closes.
pub const NEWSPAPER_AUTH_EVENT: &str = "newspaper-auth-changed";

#[derive(Debug, Clone, Deserialize)]
pub struct NewspaperSection {
    pub title: String,
    pub url: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Newspaper {
    pub id: String,
    pub name: String,
    pub site: String,
    pub domains: Vec<String>,
    /// "subscription" or "free".
    pub access: String,
    #[serde(default)]
    pub sign_in: Option<String>,
    #[serde(default)]
    pub session_cookies: Vec<String>,
    pub sections: Vec<NewspaperSection>,
}

#[derive(Deserialize)]
struct NewspaperFile {
    newspapers: Vec<Newspaper>,
}

pub fn newspapers() -> &'static [Newspaper] {
    static LIST: OnceLock<Vec<Newspaper>> = OnceLock::new();
    LIST.get_or_init(|| {
        serde_json::from_str::<NewspaperFile>(NEWSPAPERS_JSON)
            .map(|f| f.newspapers)
            .unwrap_or_default()
    })
}

/// True when `host` is `domain` or one of its subdomains.
fn host_matches(host: &str, domain: &str) -> bool {
    let host = host.trim_end_matches('.').to_ascii_lowercase();
    let domain = domain.trim_start_matches('.').to_ascii_lowercase();
    host == domain || host.ends_with(&format!(".{domain}"))
}

/// The paper an article or cookie host belongs to, if any.
pub fn newspaper_for_host(host: &str) -> Option<&'static Newspaper> {
    newspapers()
        .iter()
        .find(|paper| paper.domains.iter().any(|d| host_matches(host, d)))
}

fn newspaper_for_url(url: &str) -> Option<&'static Newspaper> {
    let parsed = url::Url::parse(url).ok()?;
    newspaper_for_host(parsed.host_str()?)
}

/// A paper's cookies as read from the WebKit store, one `name=value` per entry.
#[derive(Debug, Clone, Default, PartialEq)]
struct PaperCookies {
    pairs: Vec<(String, String)>,
}

fn cookie_jar() -> &'static RwLock<HashMap<String, PaperCookies>> {
    static JAR: OnceLock<RwLock<HashMap<String, PaperCookies>>> = OnceLock::new();
    JAR.get_or_init(|| RwLock::new(HashMap::new()))
}

/// The `Cookie` header to send with a reader fetch of `url`: the signed-in
/// cookies of the paper that published it, and nothing for any other site.
pub fn cookie_header_for(url: &str) -> Option<String> {
    let paper = newspaper_for_url(url)?;
    let jar = cookie_jar().read().ok()?;
    let cookies = jar.get(&paper.id)?;
    if cookies.pairs.is_empty() {
        return None;
    }
    Some(
        cookies
            .pairs
            .iter()
            .map(|(name, value)| format!("{name}={value}"))
            .collect::<Vec<_>>()
            .join("; "),
    )
}

/// Groups WebKit cookies by paper. Cookies from other sites are dropped.
fn group_cookies<'a>(cookies: impl IntoIterator<Item = (&'a str, &'a str, &'a str)>) -> HashMap<String, PaperCookies> {
    let mut out: HashMap<String, PaperCookies> = HashMap::new();
    for (domain, name, value) in cookies {
        if let Some(paper) = newspaper_for_host(domain) {
            let entry = out.entry(paper.id.clone()).or_default();
            if !entry.pairs.iter().any(|(n, _)| n == name) {
                entry.pairs.push((name.to_string(), value.to_string()));
            }
        }
    }
    out
}

/// Reads every paper's cookies back from the shared WebKit store.
pub fn refresh_cookie_jar(app: &AppHandle) {
    let Some(webview) = app.webview_windows().into_values().next() else { return };
    let Ok(cookies) = webview.cookies() else { return };
    let grouped = group_cookies(
        cookies
            .iter()
            .filter_map(|c| Some((c.domain()?, c.name(), c.value()))),
    );
    if let Ok(mut jar) = cookie_jar().write() {
        *jar = grouped;
    }
}

fn connected_key(id: &str) -> String {
    format!("newspaper_signed_in.{id}")
}

/// Signed in: the paper's login cookie is present, or, for papers whose login
/// cookie Skim does not know, the reader finished signing in and the paper
/// still has cookies.
fn signed_in(paper: &Newspaper, marked: bool, cookies: Option<&PaperCookies>) -> bool {
    let Some(cookies) = cookies.filter(|c| !c.pairs.is_empty()) else { return false };
    if paper.session_cookies.is_empty() {
        return marked;
    }
    cookies
        .pairs
        .iter()
        .any(|(name, _)| paper.session_cookies.iter().any(|s| s == name))
}

#[derive(Debug, Serialize)]
pub struct NewspaperView {
    pub id: String,
    pub name: String,
    pub site: String,
    pub icon_url: Option<String>,
    pub free: bool,
    pub can_sign_in: bool,
    pub signed_in: bool,
    pub sections: Vec<DiscoveredFeed>,
}

fn section_feed(paper: &Newspaper, section: &NewspaperSection) -> DiscoveredFeed {
    let mut feed = discovery::catalog_entry(&CatalogFeed {
        title: section.title.clone(),
        url: section.url.clone(),
        site: paper.site.clone(),
        description: section.title.clone(),
    });
    feed.description = None;
    feed
}

/// Every newspaper with its sections, what the reader follows, and whether
/// they are signed in.
#[tauri::command]
pub async fn list_newspapers(app: AppHandle, db: State<'_, Database>) -> Result<Vec<NewspaperView>, String> {
    refresh_cookie_jar(&app);
    let existing: std::collections::HashSet<String> = {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        queries::list_feeds(&conn)
            .map_err(|e| e.to_string())?
            .into_iter()
            .map(|f| super::feeds::normalize_feed_url(&f.url))
            .collect()
    };
    let jar = cookie_jar().read().map_err(|e| e.to_string())?.clone();
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    Ok(newspapers()
        .iter()
        .map(|paper| {
            let marked = queries::get_setting(&conn, &connected_key(&paper.id))
                .ok()
                .flatten()
                .is_some();
            let sections = paper
                .sections
                .iter()
                .map(|s| {
                    let mut feed = section_feed(paper, s);
                    feed.already_subscribed = existing.contains(&super::feeds::normalize_feed_url(&s.url));
                    feed
                })
                .collect();
            NewspaperView {
                id: paper.id.clone(),
                name: paper.name.clone(),
                site: paper.site.clone(),
                icon_url: crate::feed::fetcher::favicon_url(&paper.site),
                free: paper.access == "free",
                can_sign_in: paper.sign_in.is_some(),
                signed_in: paper.sign_in.is_some() && signed_in(paper, marked, jar.get(&paper.id)),
                sections,
            }
        })
        .collect())
}

/// Drops reader copies saved before the sign-in changed, so the paper's
/// articles fetch again with (or without) the subscriber's access.
fn forget_reader_copies(db: &Database, paper: &Newspaper) -> Result<(), String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    let mut stmt = conn
        .prepare("SELECT article_id, url FROM article_reader_cache WHERE url IS NOT NULL")
        .map_err(|e| e.to_string())?;
    let stale: Vec<String> = stmt
        .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))
        .map_err(|e| e.to_string())?
        .filter_map(Result::ok)
        .filter(|(_, url)| newspaper_for_url(url).is_some_and(|p| p.id == paper.id))
        .map(|(id, _)| id)
        .collect();
    drop(stmt);
    for id in stale {
        conn.execute("DELETE FROM article_reader_cache WHERE article_id = ?1", [&id])
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

fn paper_by_id(id: &str) -> Result<&'static Newspaper, String> {
    newspapers()
        .iter()
        .find(|p| p.id == id)
        .ok_or_else(|| format!("Unknown newspaper {id}"))
}

/// True when the sign-in browser has left the login pages for the paper's
/// own site, which is where every paper sends a reader who signed in.
fn finished_sign_in(paper: &Newspaper, url: &url::Url) -> bool {
    let Some(host) = url.host_str() else { return false };
    let host = host.to_ascii_lowercase();
    if !paper.domains.iter().any(|d| host_matches(&host, d)) {
        return false;
    }
    // The paper's account and login hosts (accounts.wsj.com) don't count.
    const ACCOUNT_HOSTS: [&str; 10] = ["accounts", "account", "myaccount", "sso", "login", "auth", "id", "secure", "subscribe", "profile"];
    if host.split('.').any(|label| ACCOUNT_HOSTS.contains(&label)) {
        return false;
    }
    let path = url.path().to_ascii_lowercase();
    !["login", "signin", "sign-in", "subscribe", "account", "auth", "register", "callback"]
        .iter()
        .any(|word| path.contains(word))
}

/// Opens the paper's login page in a Skim window. When the page sends the
/// reader on to the paper's site, the sign-in is done: the window closes and
/// Skim reads the paper's cookies back and refetches its articles.
#[tauri::command]
pub async fn sign_in_newspaper(app: AppHandle, id: String) -> Result<(), String> {
    let paper = paper_by_id(&id)?;
    let sign_in = paper
        .sign_in
        .as_deref()
        .ok_or_else(|| format!("{} is free to read; there is nothing to sign in to.", paper.name))?;
    let url: url::Url = sign_in.parse().map_err(|e| format!("Bad sign-in address: {e}"))?;
    if let Some(existing) = app.get_webview_window(SIGN_IN_WINDOW) {
        let _ = existing.destroy();
    }
    let finished = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let nav_finished = finished.clone();
    let nav_app = app.clone();
    let window = tauri::WebviewWindowBuilder::new(&app, SIGN_IN_WINDOW, tauri::WebviewUrl::External(url))
        .title(format!("Sign in to {}", paper.name))
        .inner_size(520.0, 760.0)
        .min_inner_size(380.0, 520.0)
        .on_navigation(move |url| {
            if finished_sign_in(paper, url) && !nav_finished.swap(true, std::sync::atomic::Ordering::SeqCst) {
                let app = nav_app.clone();
                tauri::async_runtime::spawn(async move {
                    // Let the site finish setting its cookies before closing.
                    tokio::time::sleep(std::time::Duration::from_millis(1500)).await;
                    if let Some(window) = app.get_webview_window(SIGN_IN_WINDOW) {
                        let _ = window.close();
                    }
                });
            }
            true
        })
        .build()
        .map_err(|e| format!("Couldn't open the sign-in window: {e}"))?;
    let handle = app.clone();
    let paper_id = paper.id.clone();
    window.on_window_event(move |event| {
        if matches!(event, tauri::WindowEvent::Destroyed) {
            let handle = handle.clone();
            let paper_id = paper_id.clone();
            let finished = finished.load(std::sync::atomic::Ordering::SeqCst);
            tauri::async_runtime::spawn(async move {
                refresh_cookie_jar(&handle);
                let db = handle.state::<Database>();
                if let Ok(paper) = paper_by_id(&paper_id) {
                    if finished {
                        let Ok(conn) = db.conn.lock();
                        let _ = queries::set_setting(&conn, &connected_key(&paper.id), "1");
                    }
                    let _ = forget_reader_copies(db.inner(), paper);
                }
                let _ = handle.emit(NEWSPAPER_AUTH_EVENT, &paper_id);
            });
        }
    });
    Ok(())
}

/// Forgets the paper's cookies, so its articles load as they do for anyone.
#[tauri::command]
pub async fn sign_out_newspaper(app: AppHandle, db: State<'_, Database>, id: String) -> Result<(), String> {
    let paper = paper_by_id(&id)?;
    if let Some(webview) = app.webview_windows().into_values().next() {
        let cookies = webview.cookies().map_err(|e| e.to_string())?;
        for cookie in cookies {
            if cookie.domain().and_then(newspaper_for_host).is_some_and(|p| p.id == paper.id) {
                let _ = webview.delete_cookie(cookie);
            }
        }
    }
    {
        let conn = db.conn.lock().map_err(|e| e.to_string())?;
        conn.execute("DELETE FROM settings WHERE key = ?1", [connected_key(&paper.id)])
            .map_err(|e| e.to_string())?;
    }
    refresh_cookie_jar(&app);
    forget_reader_copies(db.inner(), paper)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_lists_the_five_papers_with_sections() {
        let ids: Vec<&str> = newspapers().iter().map(|p| p.id.as_str()).collect();
        assert_eq!(ids, ["nyt", "wsj", "wapo", "ft", "guardian"]);
        for paper in newspapers() {
            assert!(paper.sections.len() >= 5, "{} has too few sections", paper.id);
            assert!(paper.sections.iter().all(|s| s.url.starts_with("https://")));
            assert_eq!(paper.sign_in.is_some(), paper.access == "subscription", "{}", paper.id);
        }
    }

    #[test]
    fn hosts_match_the_paper_and_its_subdomains_only() {
        assert_eq!(newspaper_for_host("www.nytimes.com").map(|p| p.id.as_str()), Some("nyt"));
        assert_eq!(newspaper_for_host(".nytimes.com").map(|p| p.id.as_str()), Some("nyt"));
        assert_eq!(newspaper_for_host("www.ft.com").map(|p| p.id.as_str()), Some("ft"));
        assert!(newspaper_for_host("notnytimes.com").is_none());
        assert!(newspaper_for_host("soft.com").is_none());
        assert!(newspaper_for_host("example.org").is_none());
    }

    #[test]
    fn cookies_go_only_to_their_own_paper() {
        let grouped = group_cookies([
            (".nytimes.com", "NYT-S", "abc"),
            ("www.nytimes.com", "nyt-a", "1"),
            (".ft.com", "FTSession_s", "xyz"),
            (".example.com", "tracker", "no"),
        ]);
        *cookie_jar().write().unwrap() = grouped;
        assert_eq!(
            cookie_header_for("https://www.nytimes.com/2026/10/27/world/x.html").as_deref(),
            Some("NYT-S=abc; nyt-a=1")
        );
        assert_eq!(cookie_header_for("https://www.ft.com/content/1").as_deref(), Some("FTSession_s=xyz"));
        assert_eq!(cookie_header_for("https://www.wsj.com/articles/x"), None);
        assert_eq!(cookie_header_for("https://example.com/a"), None);
    }

    #[test]
    fn signed_in_needs_the_login_cookie_when_one_is_known() {
        let nyt = paper_by_id("nyt").unwrap();
        let wsj = paper_by_id("wsj").unwrap();
        let anon = PaperCookies { pairs: vec![("nyt-a".into(), "1".into())] };
        let login = PaperCookies { pairs: vec![("NYT-S".into(), "1".into())] };
        assert!(!signed_in(nyt, true, Some(&anon)));
        assert!(signed_in(nyt, false, Some(&login)));
        assert!(!signed_in(nyt, true, None));
        // WSJ's login cookie isn't known: finishing sign-in with cookies counts.
        assert!(signed_in(wsj, true, Some(&anon)));
        assert!(!signed_in(wsj, false, Some(&anon)));
    }

    #[test]
    fn sign_in_finishes_on_the_papers_site_not_its_login_pages() {
        let wsj = paper_by_id("wsj").unwrap();
        let at = |u: &str| finished_sign_in(wsj, &u.parse().unwrap());
        assert!(!at("https://accounts.wsj.com/login"));
        assert!(!at("https://sso.accounts.dowjones.com/login-page?x=1"));
        assert!(!at("https://www.wsj.com/client/login"));
        assert!(!at("https://www.wsj.com/client/auth?code=1"));
        assert!(at("https://www.wsj.com/"));
        assert!(at("https://wsj.com/?mod=login"));
        assert!(at("https://www.wsj.com/news/world"));
    }
}
