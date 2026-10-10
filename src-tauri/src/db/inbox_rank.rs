//! AI Inbox ranking: learned reader taste plus the shared scoring policy also
//! compiled into the native iOS app (`shared/SkimStoryPolicy`).

use rusqlite::{params, Connection};
use std::collections::HashMap;
use std::ffi::CStr;

extern "C" {
    fn skim_inbox_triage_prompt() -> *const std::os::raw::c_char;
    fn skim_inbox_signal_weight(
        dwell_seconds: f64,
        opened: i32,
        starred: i32,
        pinned: i32,
        feedback: i32,
        read_unopened: i32,
    ) -> f64;
    fn skim_inbox_affinity(positive: f64, negative: f64) -> f64;
    fn skim_inbox_learning_strength(signal_count: i64) -> f64;
    fn skim_inbox_score(
        importance: f64,
        relevance: f64,
        has_ai: i32,
        affinity: f64,
        strength: f64,
        pinned: i32,
        age_hours: f64,
    ) -> f64;
    fn skim_inbox_priority(importance: f64, relevance: f64) -> i32;
}

pub fn triage_prompt() -> &'static str {
    // Static NUL-terminated ASCII owned by the C policy.
    unsafe { CStr::from_ptr(skim_inbox_triage_prompt()) }
        .to_str()
        .unwrap_or("")
}

#[derive(Debug, Clone, Copy, Default)]
pub struct Signal {
    pub dwell_seconds: f64,
    pub opened: bool,
    pub starred: bool,
    pub pinned: bool,
    /// -1 less, 0 none, +1 more.
    pub feedback: i32,
    pub read_unopened: bool,
}

pub fn signal_weight(s: Signal) -> f64 {
    unsafe {
        skim_inbox_signal_weight(
            s.dwell_seconds,
            i32::from(s.opened),
            i32::from(s.starred),
            i32::from(s.pinned),
            s.feedback.signum(),
            i32::from(s.read_unopened),
        )
    }
}

pub fn affinity(positive: f64, negative: f64) -> f64 {
    unsafe { skim_inbox_affinity(positive, negative) }
}

pub fn learning_strength(signals: i64) -> f64 {
    unsafe { skim_inbox_learning_strength(signals) }
}

pub struct ScoreInput {
    pub importance: Option<i32>,
    pub relevance: Option<i32>,
    pub affinity: f64,
    pub strength: f64,
    pub pinned: bool,
    pub age_hours: f64,
}

pub fn score(input: &ScoreInput) -> f64 {
    let has_ai = input.importance.is_some() && input.relevance.is_some();
    unsafe {
        skim_inbox_score(
            input.importance.unwrap_or(0) as f64,
            input.relevance.unwrap_or(0) as f64,
            i32::from(has_ai),
            input.affinity,
            input.strength,
            i32::from(input.pinned),
            input.age_hours,
        )
    }
}

pub fn priority(importance: i32, relevance: i32) -> i32 {
    unsafe { skim_inbox_priority(importance as f64, relevance as f64) }
}

const STOPWORDS: &[&str] = &[
    "the", "and", "for", "that", "this", "with", "from", "your", "about", "into", "over",
    "have", "has", "been", "were", "was", "are", "not", "how", "why", "when", "what", "who",
    "which", "will", "just", "its", "they", "them", "their", "there", "these", "those", "then",
    "than", "because", "also", "some", "more", "most", "like", "between", "against", "upon",
    "after", "before", "during", "only", "such", "any", "all", "but", "can", "you", "our",
    "says", "said", "new",
];

/// Distinct lowercase title words of four or more letters, in title order.
pub fn terms(title: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for word in title.to_lowercase().split(|c: char| !c.is_alphanumeric()) {
        if word.chars().count() < 4 || STOPWORDS.contains(&word) {
            continue;
        }
        if word.chars().all(|c| c.is_ascii_digit()) {
            continue;
        }
        if !out.iter().any(|w| w == word) {
            out.push(word.to_string());
        }
    }
    out
}

#[derive(Default, Clone, Copy)]
struct Tally {
    positive: f64,
    negative: f64,
}

impl Tally {
    fn add(&mut self, weight: f64) {
        if weight >= 0.0 {
            self.positive += weight;
        } else {
            self.negative -= weight;
        }
    }
    fn affinity(&self) -> f64 {
        affinity(self.positive, self.negative)
    }
}

/// What the reader has taught the inbox, learned only from local history.
#[derive(Default)]
pub struct TasteModel {
    feeds: HashMap<String, Tally>,
    terms: HashMap<String, Tally>,
    signals: i64,
}

impl TasteModel {
    pub fn learn(&mut self, feed_id: &str, title: &str, signal: Signal) {
        let weight = signal_weight(signal);
        if weight == 0.0 {
            return;
        }
        self.signals += 1;
        self.feeds.entry(feed_id.to_string()).or_default().add(weight);
        for term in terms(title) {
            self.terms.entry(term).or_default().add(weight);
        }
    }

    pub fn strength(&self) -> f64 {
        learning_strength(self.signals)
    }

    /// Feed and title-term affinity, -1..1. Terms seen once barely move it.
    pub fn affinity(&self, feed_id: &str, title: &str) -> f64 {
        let feed = self.feeds.get(feed_id).map(Tally::affinity).unwrap_or(0.0);
        let known: Vec<f64> = terms(title)
            .iter()
            .filter_map(|t| self.terms.get(t))
            .map(Tally::affinity)
            .collect();
        if known.is_empty() {
            return feed;
        }
        let term = known.iter().sum::<f64>() / known.len() as f64;
        0.5 * feed + 0.5 * term
    }
}

/// Build the taste model from reading time, chats, stars, pins, feedback and
/// inbox articles dismissed without being opened.
pub fn load_taste(conn: &Connection) -> Result<TasteModel, rusqlite::Error> {
    let mut stmt = conn.prepare(
        "SELECT a.feed_id, a.title,
                COALESCE(i.reading_time_sec, 0), COALESCE(i.chat_messages, 0),
                a.is_starred, COALESCE(i.priority_override, 0), i.feedback,
                a.is_read, t.article_id IS NOT NULL
         FROM articles a
         LEFT JOIN article_interactions i ON i.article_id = a.id
         LEFT JOIN article_triage t ON t.article_id = a.id
         WHERE i.article_id IS NOT NULL OR a.is_starred = 1
            OR (a.is_read = 1 AND t.article_id IS NOT NULL)
         ORDER BY COALESCE(i.updated_at, a.fetched_at) DESC
         LIMIT ?1",
    )?;
    let mut model = TasteModel::default();
    let rows = stmt.query_map(params![3000], |row| {
        let reading: i64 = row.get(2)?;
        let chats: i64 = row.get(3)?;
        let feedback: Option<String> = row.get(6)?;
        let opened = reading > 0 || chats > 0;
        let signal = Signal {
            dwell_seconds: (reading + chats * 60) as f64,
            opened,
            starred: row.get::<_, i32>(4)? != 0,
            pinned: row.get::<_, i32>(5)? >= 5,
            feedback: match feedback.as_deref() {
                Some("more") => 1,
                Some("less") => -1,
                _ => 0,
            },
            read_unopened: row.get::<_, i32>(7)? != 0 && row.get::<_, bool>(8)? && !opened,
        };
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, signal))
    })?;
    for row in rows.flatten() {
        model.learn(&row.0, &row.1, row.2);
    }
    Ok(model)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;

    #[derive(Deserialize)]
    struct Fixture {
        signal_weights: Vec<WeightCase>,
        affinity: Vec<AffinityCase>,
        strength: Vec<StrengthCase>,
        scores: Vec<ScoreCase>,
        priority: Vec<PriorityCase>,
        terms: Vec<TermsCase>,
    }
    #[derive(Deserialize)]
    struct WeightCase {
        name: String,
        dwell: f64,
        opened: bool,
        starred: bool,
        pinned: bool,
        feedback: i32,
        read_unopened: bool,
        weight: f64,
    }
    #[derive(Deserialize)]
    struct AffinityCase {
        positive: f64,
        negative: f64,
        affinity: f64,
    }
    #[derive(Deserialize)]
    struct StrengthCase {
        signals: i64,
        strength: f64,
    }
    #[derive(Deserialize)]
    struct ScoreCase {
        name: String,
        importance: i32,
        relevance: i32,
        has_ai: bool,
        affinity: f64,
        strength: f64,
        pinned: bool,
        age_hours: f64,
        score: f64,
    }
    #[derive(Deserialize)]
    struct PriorityCase {
        importance: i32,
        relevance: i32,
        priority: i32,
    }
    #[derive(Deserialize)]
    struct TermsCase {
        title: String,
        terms: Vec<String>,
    }

    fn fixture() -> Fixture {
        serde_json::from_str(include_str!("../../../shared/fixtures/inbox-ranking.json")).unwrap()
    }

    #[test]
    fn shared_inbox_fixture() {
        let f = fixture();
        for c in f.signal_weights {
            let w = signal_weight(Signal {
                dwell_seconds: c.dwell,
                opened: c.opened,
                starred: c.starred,
                pinned: c.pinned,
                feedback: c.feedback,
                read_unopened: c.read_unopened,
            });
            assert!((w - c.weight).abs() < 1e-9, "{}: {w}", c.name);
        }
        for c in f.affinity {
            assert!((affinity(c.positive, c.negative) - c.affinity).abs() < 1e-9);
        }
        for c in f.strength {
            assert!((learning_strength(c.signals) - c.strength).abs() < 1e-9);
        }
        for c in f.scores {
            let s = score(&ScoreInput {
                importance: c.has_ai.then_some(c.importance),
                relevance: c.has_ai.then_some(c.relevance),
                affinity: c.affinity,
                strength: c.strength,
                pinned: c.pinned,
                age_hours: c.age_hours,
            });
            assert!((s - c.score).abs() < 1e-9, "{}: {s}", c.name);
        }
        for c in f.priority {
            assert_eq!(priority(c.importance, c.relevance), c.priority);
        }
        for c in f.terms {
            assert_eq!(terms(&c.title), c.terms, "{}", c.title);
        }
        assert!(triage_prompt().contains("importance"));
    }

    #[test]
    fn taste_learns_from_reading_and_dismissals() {
        let mut taste = TasteModel::default();
        for _ in 0..4 {
            taste.learn("rust", "Rust compiler gets faster builds", Signal {
                dwell_seconds: 200.0, opened: true, ..Default::default()
            });
            taste.learn("gossip", "Celebrity gossip roundup", Signal {
                read_unopened: true, ..Default::default()
            });
        }
        assert!(taste.affinity("rust", "Faster compiler releases") > 0.5);
        assert!(taste.affinity("gossip", "Weekly gossip") < 0.0);
        assert_eq!(taste.affinity("unknown", "Nothing in common"), 0.0);
        assert!(taste.strength() > 0.0);
    }
}
