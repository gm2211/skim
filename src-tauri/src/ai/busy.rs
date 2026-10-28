//! Rate limits and overloads from Claude. A 429 or overloaded answer is asked
//! again after a short wait (honouring `retry-after`) before it becomes an
//! error, and a 429 that outlasts the retries starts a cooldown: until it ends,
//! requests to that provider stop right away with a plain message instead of
//! asking again into a closed window.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use reqwest::header::HeaderMap;

/// Longest wait Skim sits through before asking again.
pub const WAIT_LIMIT: Duration = Duration::from_secs(20);
/// Cooldown after a 429 that doesn't say how long to wait.
const DEFAULT_COOLDOWN: Duration = Duration::from_secs(60);

#[cfg(not(test))]
const BACKOFF: [Duration; 2] = [Duration::from_secs(2), Duration::from_secs(6)];
#[cfg(test)]
const BACKOFF: [Duration; 2] = [Duration::ZERO; 2];

/// What a 429 or overloaded response says about when to ask again.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct BusySignal {
    pub retry_after: Option<Duration>,
    /// When the plan's usage window reopens (Claude sign-in).
    pub resets_at: Option<SystemTime>,
    /// The plan's window is closed rather than the requests being too fast.
    pub plan_limit_reached: bool,
}

impl BusySignal {
    pub fn from_headers(headers: &HeaderMap) -> Self {
        let header = |name: &str| headers.get(name).and_then(|v| v.to_str().ok()).map(str::trim);
        let retry_after = header("retry-after")
            .and_then(|v| v.parse::<f64>().ok())
            .filter(|s| s.is_finite() && *s >= 0.0)
            .map(Duration::from_secs_f64);
        let resets_at = header("anthropic-ratelimit-unified-reset")
            .and_then(|v| v.parse::<u64>().ok())
            .map(|secs| UNIX_EPOCH + Duration::from_secs(secs))
            .filter(|at| *at > SystemTime::now());
        let plan_limit_reached = header("anthropic-ratelimit-unified-status")
            .is_some_and(|v| v.eq_ignore_ascii_case("rejected"));
        Self { retry_after, resets_at, plan_limit_reached }
    }

    fn until_reset(&self) -> Option<Duration> {
        self.resets_at.and_then(|at| at.duration_since(SystemTime::now()).ok())
    }

    /// How long to wait before asking again, when the provider said.
    pub fn wait(&self) -> Option<Duration> {
        if self.plan_limit_reached {
            if let Some(reset) = self.until_reset() {
                return Some(reset);
            }
        }
        self.retry_after.or_else(|| self.until_reset())
    }
}

fn error_message(body: &str) -> Option<String> {
    serde_json::from_str::<serde_json::Value>(body)
        .ok()
        .and_then(|v| v["error"]["message"].as_str().map(str::to_string))
}

fn informative(detail: &str) -> bool {
    let trimmed = detail.trim();
    trimmed.chars().count() > 10 && !trimmed.eq_ignore_ascii_case("error")
}

/// Claude's bare 429 "Error": no `retry-after`, no usage window, no reason.
/// It turns the request itself down, so asking again gets the same answer.
pub fn is_refusal_429(body: &str, signal: &BusySignal) -> bool {
    !error_message(body).is_some_and(|m| informative(&m))
        && signal.retry_after.is_none()
        && signal.resets_at.is_none()
        && !signal.plan_limit_reached
}

/// The message for a real rate limit: when it lifts if Claude said, never
/// Claude's boilerplate ("This request would exceed your account's rate
/// limit"), which only repeats the headline.
pub fn rate_limit_message(subscription: bool, body: &str, signal: &BusySignal) -> String {
    let wait = signal.wait();
    if let Some(resets_at) = signal.resets_at {
        if signal.plan_limit_reached || wait.is_some_and(|w| w > Duration::from_secs(15 * 60)) {
            let when = chrono::DateTime::<chrono::Local>::from(resets_at);
            let today = chrono::Local::now().date_naive() == when.date_naive();
            let when = if today { when.format("at %-I:%M %p") } else { when.format("on %A at %-I:%M %p") };
            let shared = if subscription { " Claude.ai and Claude Code count toward the same limit." } else { "" };
            return format!("You've reached your Claude plan's usage limit. It resets {when}.{shared}");
        }
    }
    let mut message = match wait {
        Some(w) if !w.is_zero() => {
            let minutes = w.as_secs().div_ceil(60).max(1);
            if minutes == 1 {
                "Claude has hit your account's rate limit. Try again in a minute.".to_string()
            } else {
                format!("Claude has hit your account's rate limit. Try again in {minutes} minutes.")
            }
        }
        _ => "Claude has hit your account's rate limit for the moment. Try again in a minute.".to_string(),
    };
    if let Some(detail) = error_message(body).filter(|d| informative(d)) {
        if !detail.to_lowercase().contains("would exceed your account's rate limit") {
            let reason: String = detail.chars().take(160).collect();
            message.push_str(&format!(" ({reason})"));
        }
    }
    message
}

pub const OVERLOADED_MESSAGE: &str = "Claude is overloaded right now. Try again in a minute.";

fn cooldowns() -> &'static Mutex<HashMap<String, (Instant, String)>> {
    static COOLDOWNS: OnceLock<Mutex<HashMap<String, (Instant, String)>>> = OnceLock::new();
    COOLDOWNS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Time left on `provider`'s cooldown and the message it ended with.
pub fn cooldown(provider: &str) -> Option<(Duration, String)> {
    let mut map = cooldowns().lock().ok()?;
    let (until, message) = map.get(provider)?.clone();
    let now = Instant::now();
    if until <= now {
        map.remove(provider);
        return None;
    }
    Some((until - now, message))
}

fn record_cooldown(provider: &str, wait: Duration, message: String) {
    if let Ok(mut map) = cooldowns().lock() {
        let until = Instant::now() + wait;
        if map.get(provider).is_none_or(|(existing, _)| *existing < until) {
            map.insert(provider.to_string(), (until, message));
        }
    }
}

fn clear_cooldown(provider: &str) {
    if let Ok(mut map) = cooldowns().lock() {
        map.remove(provider);
    }
}

/// Sends the request `build` makes, asking again when Claude is rate-limited
/// or overloaded. Any other failure comes back as `fail(status, body)`; a busy
/// answer that outlasts the retries comes back as a plain message.
pub async fn send<B, F>(provider: &str, subscription: bool, build: B, fail: F) -> Result<reqwest::Response, String>
where
    B: Fn() -> reqwest::RequestBuilder,
    F: Fn(reqwest::StatusCode, &str) -> String,
{
    if let Some((remaining, message)) = cooldown(provider) {
        if remaining > WAIT_LIMIT {
            return Err(message);
        }
        tokio::time::sleep(remaining).await;
    }
    let mut attempt = 0;
    loop {
        let response = build().send().await.map_err(|e| format!("{provider} request failed: {e}"))?;
        let status = response.status();
        if status.is_success() {
            clear_cooldown(provider);
            return Ok(response);
        }
        if ![429, 503, 529].contains(&status.as_u16()) {
            let body = response.text().await.unwrap_or_default();
            return Err(fail(status, &body));
        }
        let signal = BusySignal::from_headers(response.headers());
        let body = response.text().await.unwrap_or_default();
        log::warn!(
            "{provider} busy ({status}), attempt {}, wait {:?}, plan limit {}",
            attempt + 1,
            signal.wait(),
            signal.plan_limit_reached
        );
        if status.as_u16() == 429 && is_refusal_429(&body, &signal) {
            return Err(fail(status, &body));
        }
        let wait = signal.wait();
        let can_retry = attempt < BACKOFF.len()
            && !signal.plan_limit_reached
            && wait.is_none_or(|w| w <= WAIT_LIMIT);
        if !can_retry {
            if status.as_u16() == 429 {
                let message = rate_limit_message(subscription, &body, &signal);
                record_cooldown(provider, wait.unwrap_or(DEFAULT_COOLDOWN), message.clone());
                return Err(message);
            }
            return Err(OVERLOADED_MESSAGE.to_string());
        }
        tokio::time::sleep(wait.unwrap_or_default().max(BACKOFF[attempt])).await;
        attempt += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use reqwest::header::HeaderValue;

    const RATE_LIMIT: &str = r#"{"type":"error","error":{"type":"rate_limit_error","message":"This request would exceed your account's rate limit. Please try again later."}}"#;

    #[test]
    fn claudes_boilerplate_is_left_out_of_the_message() {
        let message = rate_limit_message(true, RATE_LIMIT, &BusySignal::default());
        assert_eq!(message, "Claude has hit your account's rate limit for the moment. Try again in a minute.");
    }

    #[test]
    fn retry_after_says_when_to_try_again() {
        let signal = BusySignal { retry_after: Some(Duration::from_secs(150)), ..Default::default() };
        assert_eq!(rate_limit_message(false, RATE_LIMIT, &signal), "Claude has hit your account's rate limit. Try again in 3 minutes.");
    }

    #[test]
    fn a_closed_plan_window_says_when_it_resets() {
        let mut headers = HeaderMap::new();
        let reset = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs() + 3 * 3600;
        headers.insert("anthropic-ratelimit-unified-status", HeaderValue::from_static("rejected"));
        headers.insert("anthropic-ratelimit-unified-reset", HeaderValue::from_str(&reset.to_string()).unwrap());
        let signal = BusySignal::from_headers(&headers);
        assert!(signal.plan_limit_reached);
        assert!(signal.wait().unwrap() > Duration::from_secs(2 * 3600));
        let message = rate_limit_message(true, RATE_LIMIT, &signal);
        assert!(message.starts_with("You've reached your Claude plan's usage limit. It resets "), "{message}");
        assert!(message.ends_with("Claude.ai and Claude Code count toward the same limit."), "{message}");
    }

    #[test]
    fn a_bare_error_is_a_refusal_not_a_rate_limit() {
        let bare = r#"{"type":"error","error":{"type":"rate_limit_error","message":"Error"}}"#;
        assert!(is_refusal_429(bare, &BusySignal::default()));
        assert!(!is_refusal_429(RATE_LIMIT, &BusySignal::default()));
        let signal = BusySignal { retry_after: Some(Duration::from_secs(5)), ..Default::default() };
        assert!(!is_refusal_429(bare, &signal));
    }

    #[test]
    fn rate_limit_messages_read_as_transient_to_today() {
        let message = rate_limit_message(true, RATE_LIMIT, &BusySignal::default());
        assert!(crate::commands::editions::transient_model_error(&message));
        assert!(crate::commands::editions::transient_model_error(OVERLOADED_MESSAGE));
    }

    /// Serves `replies` in order, one per connection, and counts requests.
    async fn stub_server(replies: Vec<(u16, &'static str)>) -> (String, std::sync::Arc<std::sync::atomic::AtomicUsize>) {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/v1/messages", listener.local_addr().unwrap());
        let count = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let served = count.clone();
        tokio::spawn(async move {
            for (status, body) in replies {
                let Ok((mut stream, _)) = listener.accept().await else { return };
                let mut buf = vec![0u8; 8192];
                let _ = stream.read(&mut buf).await;
                served.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                let reply = format!(
                    "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = stream.write_all(reply.as_bytes()).await;
            }
        });
        (url, count)
    }

    #[tokio::test]
    async fn a_rate_limit_is_asked_again_before_it_becomes_an_error() {
        let (url, count) = stub_server(vec![(429, RATE_LIMIT), (200, "{}")]).await;
        let client = reqwest::Client::new();
        let response = send("stub-retry", true, || client.post(&url), |s, b| format!("{s} {b}")).await;
        assert!(response.is_ok());
        assert_eq!(count.load(std::sync::atomic::Ordering::SeqCst), 2);
        assert!(cooldown("stub-retry").is_none());
    }

    #[tokio::test]
    async fn a_lasting_rate_limit_becomes_a_plain_message_and_a_cooldown() {
        let (url, count) = stub_server(vec![(429, RATE_LIMIT); 4]).await;
        let client = reqwest::Client::new();
        let error = send("stub-cooldown", true, || client.post(&url), |s, b| format!("{s} {b}")).await.unwrap_err();
        assert_eq!(error, "Claude has hit your account's rate limit for the moment. Try again in a minute.");
        assert_eq!(count.load(std::sync::atomic::Ordering::SeqCst), 3);
        // The next request stops before the network.
        let again = send("stub-cooldown", true, || client.post(&url), |s, b| format!("{s} {b}")).await.unwrap_err();
        assert_eq!(again, error);
        assert_eq!(count.load(std::sync::atomic::Ordering::SeqCst), 3);
        clear_cooldown("stub-cooldown");
    }

    #[tokio::test]
    async fn other_failures_keep_their_own_error() {
        let bare = r#"{"type":"error","error":{"type":"rate_limit_error","message":"Error"}}"#;
        let (url, count) = stub_server(vec![(429, bare)]).await;
        let client = reqwest::Client::new();
        let error = send("stub-bare", true, || client.post(&url), |s, _| format!("failed {}", s.as_u16())).await.unwrap_err();
        assert_eq!(error, "failed 429");
        assert_eq!(count.load(std::sync::atomic::Ordering::SeqCst), 1);
        assert!(cooldown("stub-bare").is_none());
    }

    #[test]
    fn a_cooldown_stops_requests_until_it_ends() {
        record_cooldown("test-provider", Duration::from_secs(120), "wait".into());
        let (remaining, message) = cooldown("test-provider").unwrap();
        assert!(remaining > WAIT_LIMIT);
        assert_eq!(message, "wait");
        clear_cooldown("test-provider");
        assert!(cooldown("test-provider").is_none());
    }
}
