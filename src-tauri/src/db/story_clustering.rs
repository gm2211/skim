//! Deterministic, offline story clustering and edition ranking.
//!
//! This module is an additive index over `articles`: it never mutates, deletes,
//! or suppresses raw feed rows. Borderline matches are persisted for a future
//! arbiter, but conservatively remain separate stories today.

use crate::db::models::{Article, Story, StoryArticle, StoryMembershipType, StoryRevision};
use crate::db::queries;
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use url::Url;

pub const ROLLING_WINDOW_SECONDS: i64 = 96 * 60 * 60;
pub const DUPLICATE_THRESHOLD: f64 = 0.88;
pub const COVERAGE_THRESHOLD: f64 = 0.68;
pub const BORDERLINE_THRESHOLD: f64 = 0.58;
const FEATURE_VERSION: i64 = 1;

#[derive(Debug, Clone, PartialEq)]
pub struct MatchDecision {
    pub story_id: Option<String>,
    pub membership_type: Option<StoryMembershipType>,
    pub confidence: f64,
    pub borderline_story_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ClusterAssignment {
    pub story_id: String,
    pub membership_type: StoryMembershipType,
    pub confidence: f64,
    pub created_story: bool,
    pub borderline_story_id: Option<String>,
}

#[allow(dead_code)]
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct RankedStory {
    pub story_id: String,
    pub score: f64,
    pub distinct_source_count: i64,
    pub raw_article_count: i64,
    pub is_unique_find: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ArticleFeatures {
    canonical_url: Option<String>,
    normalized_title: String,
    normalized_lead: String,
    tokens: Vec<String>,
    entities: Vec<String>,
    content_hash: String,
}

#[derive(Debug)]
struct CandidateArticle {
    story_id: String,
    published_at: i64,
    features: ArticleFeatures,
}

/// Removes fragments and tracking query parameters, sorts the remaining query
/// pairs, and collapses default-port and trailing-slash differences.
pub fn canonical_article_url(raw: &str) -> Option<String> {
    let mut parsed = Url::parse(raw.trim()).ok()?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return None;
    }
    parsed.set_fragment(None);
    let mut pairs: Vec<(String, String)> = parsed
        .query_pairs()
        .filter(|(key, _)| !is_tracking_parameter(key))
        .map(|(key, value)| (key.into_owned(), value.into_owned()))
        .collect();
    pairs.sort();
    parsed.set_query(None);
    if !pairs.is_empty() {
        parsed
            .query_pairs_mut()
            .extend_pairs(pairs.iter().map(|(key, value)| (&key[..], &value[..])));
    }
    if (parsed.scheme() == "http" && parsed.port() == Some(80))
        || (parsed.scheme() == "https" && parsed.port() == Some(443))
    {
        let _ = parsed.set_port(None);
    }
    if parsed.path() == "/" {
        parsed.set_path("");
    } else if parsed.path().ends_with('/') {
        let trimmed = parsed.path().trim_end_matches('/').to_string();
        parsed.set_path(&trimmed);
    }
    Some(parsed.to_string())
}

fn is_tracking_parameter(key: &str) -> bool {
    let key = key.to_ascii_lowercase();
    key.starts_with("utm_")
        || matches!(
            key.as_str(),
            "fbclid"
                | "gclid"
                | "dclid"
                | "mc_cid"
                | "mc_eid"
                | "ref"
                | "ref_src"
                | "source"
                | "referrer"
        )
}

/// Lowercases, removes punctuation, collapses whitespace, and strips a common
/// publisher suffix. Unicode letters and digits remain intact.
pub fn normalized_story_title(title: &str) -> String {
    let separator = [" | ", " — ", " – "]
        .iter()
        .filter_map(|separator| title.rfind(separator).map(|index| (index, *separator)))
        .max_by_key(|(index, _)| *index);
    let without_suffix = separator
        .and_then(|(index, separator)| {
            let suffix = &title[index + separator.len()..];
            (suffix.split_whitespace().count() <= 4).then_some(&title[..index])
        })
        .unwrap_or(title);
    normalize_text(without_suffix)
}

fn normalize_text(value: &str) -> String {
    let mut normalized = String::with_capacity(value.len());
    let mut pending_space = false;
    for ch in value.chars().flat_map(char::to_lowercase) {
        if ch.is_alphanumeric() {
            if pending_space && !normalized.is_empty() {
                normalized.push(' ');
            }
            normalized.push(ch);
            pending_space = false;
        } else {
            pending_space = true;
        }
    }
    normalized
}

fn article_features(article: &Article) -> ArticleFeatures {
    let canonical_url = article.url.as_deref().and_then(canonical_article_url);
    let normalized_title = normalized_story_title(&article.title);
    let lead = article
        .content_text
        .as_deref()
        .or(article.content_html.as_deref())
        .unwrap_or_default()
        .chars()
        .take(700)
        .collect::<String>();
    let normalized_lead = normalize_text(&lead);
    let title_terms = significant_terms(&normalized_title);
    let mut tokens = title_terms.clone();
    tokens.extend(title_terms);
    tokens.extend(significant_terms(&normalized_lead));
    tokens.sort();
    let entities = entity_terms(&article.title);
    let content_hash = sha256(&format!(
        "{}\n{}\n{}",
        canonical_url.as_deref().unwrap_or_default(),
        normalized_title,
        normalized_lead
    ));
    ArticleFeatures {
        canonical_url,
        normalized_title,
        normalized_lead,
        tokens,
        entities,
        content_hash,
    }
}

fn significant_terms(normalized: &str) -> Vec<String> {
    normalized
        .split_whitespace()
        .filter(|term| term.chars().count() >= 3 && !STOP_WORDS.contains(term))
        .map(ToOwned::to_owned)
        .collect()
}

fn entity_terms(title: &str) -> Vec<String> {
    let mut entities = BTreeSet::new();
    for (index, raw) in title.split_whitespace().enumerate() {
        let clean = raw.trim_matches(|ch: char| !ch.is_alphanumeric());
        let is_entity = clean
            .chars()
            .next()
            .map(char::is_uppercase)
            .unwrap_or(false)
            && (index > 0 || clean.chars().all(char::is_uppercase));
        if is_entity && clean.chars().count() >= 3 {
            entities.insert(normalize_text(clean));
        }
    }
    entities.into_iter().collect()
}

const STOP_WORDS: &[&str] = &[
    "about", "after", "again", "against", "also", "and", "are", "but", "for", "from", "has",
    "have", "how", "into", "its", "more", "new", "not", "over", "says", "that", "the", "their",
    "this", "was", "were", "what", "when", "where", "which", "who", "why", "will", "with", "you",
    "your",
];

fn sha256(value: &str) -> String {
    format!("{:x}", Sha256::digest(value.as_bytes()))
}

/// Shared cross-platform stable identity: FNV-1a 64 rendered as 16 lowercase
/// hex digits with the `story-` prefix.
pub fn stable_story_id(seed: &str) -> String {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in seed.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("story-{hash:016x}")
}

fn cache_features(
    conn: &Connection,
    article: &Article,
    features: &ArticleFeatures,
) -> Result<(), rusqlite::Error> {
    let tokens_json = serde_json::to_string(&features.tokens)
        .map_err(|error| rusqlite::Error::ToSqlConversionFailure(Box::new(error)))?;
    let entities_json = serde_json::to_string(&features.entities)
        .map_err(|error| rusqlite::Error::ToSqlConversionFailure(Box::new(error)))?;
    conn.execute(
        "INSERT INTO article_story_features (
            article_id, canonical_url, normalized_title, normalized_lead,
            tokens_json, entities_json, content_hash, feature_version, computed_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
         ON CONFLICT(article_id) DO UPDATE SET
            canonical_url = excluded.canonical_url,
            normalized_title = excluded.normalized_title,
            normalized_lead = excluded.normalized_lead,
            tokens_json = excluded.tokens_json,
            entities_json = excluded.entities_json,
            content_hash = excluded.content_hash,
            feature_version = excluded.feature_version,
            computed_at = excluded.computed_at
         WHERE article_story_features.content_hash <> excluded.content_hash
            OR article_story_features.feature_version <> excluded.feature_version",
        params![
            article.id,
            features.canonical_url,
            features.normalized_title,
            features.normalized_lead,
            tokens_json,
            entities_json,
            features.content_hash,
            FEATURE_VERSION,
            article.fetched_at,
        ],
    )?;
    Ok(())
}

fn deserialize_vec(raw: String, index: usize) -> Result<Vec<String>, rusqlite::Error> {
    serde_json::from_str(&raw).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(
            index,
            rusqlite::types::Type::Text,
            Box::new(error),
        )
    })
}

fn recent_candidates(
    conn: &Connection,
    article_time: i64,
) -> Result<Vec<CandidateArticle>, rusqlite::Error> {
    let since = article_time.saturating_sub(ROLLING_WINDOW_SECONDS);
    let until = article_time.saturating_add(ROLLING_WINDOW_SECONDS);
    let mut statement = conn.prepare(
        "SELECT sa.story_id, COALESCE(a.published_at, a.fetched_at),
                af.canonical_url, af.normalized_title, af.normalized_lead,
                af.tokens_json, af.entities_json, af.content_hash
         FROM story_articles sa
         JOIN articles a ON a.id = sa.article_id
         JOIN article_story_features af ON af.article_id = a.id
         WHERE COALESCE(a.published_at, a.fetched_at) BETWEEN ?1 AND ?2
         ORDER BY COALESCE(a.published_at, a.fetched_at) DESC, sa.story_id, a.id",
    )?;
    let candidates = statement
        .query_map(params![since, until], |row| {
            Ok(CandidateArticle {
                story_id: row.get(0)?,
                published_at: row.get(1)?,
                features: ArticleFeatures {
                    canonical_url: row.get(2)?,
                    normalized_title: row.get(3)?,
                    normalized_lead: row.get(4)?,
                    tokens: deserialize_vec(row.get(5)?, 5)?,
                    entities: deserialize_vec(row.get(6)?, 6)?,
                    content_hash: row.get(7)?,
                },
            })
        })?
        .collect();
    candidates
}

fn classify(features: &ArticleFeatures, candidates: &[CandidateArticle], at: i64) -> MatchDecision {
    let mut best_match: Option<(String, StoryMembershipType, f64)> = None;
    let mut best_borderline: Option<(String, f64)> = None;
    for candidate in candidates {
        let exact_url = features.canonical_url.is_some()
            && features.canonical_url == candidate.features.canonical_url;
        let exact_title = !features.normalized_title.is_empty()
            && features.normalized_title == candidate.features.normalized_title;
        if exact_url || exact_title {
            let replace = best_match
                .as_ref()
                .map(|current| candidate.story_id < current.0)
                .unwrap_or(true);
            if replace {
                best_match = Some((
                    candidate.story_id.clone(),
                    StoryMembershipType::Duplicate,
                    1.0,
                ));
            }
            continue;
        }

        let title_similarity = jaccard(
            &significant_terms(&features.normalized_title),
            &significant_terms(&candidate.features.normalized_title),
        );
        let lexical_similarity = cosine(&features.tokens, &candidate.features.tokens);
        let entity_guard = features.entities.is_empty()
            || candidate.features.entities.is_empty()
            || overlaps(&features.entities, &candidate.features.entities);
        let confidence = (lexical_similarity * 0.65 + title_similarity * 0.35).clamp(0.0, 1.0);
        let relationship =
            if confidence >= DUPLICATE_THRESHOLD && title_similarity >= 0.78 && entity_guard {
                Some(StoryMembershipType::Duplicate)
            } else if confidence >= COVERAGE_THRESHOLD && title_similarity >= 0.45 && entity_guard {
                let novel = novelty_ratio(&features.tokens, &candidate.features.tokens) >= 0.30;
                let update_marker = contains_update_marker(&features.normalized_title);
                Some(
                    if at >= candidate.published_at && (novel || update_marker) {
                        StoryMembershipType::Update
                    } else {
                        StoryMembershipType::Coverage
                    },
                )
            } else {
                None
            };
        if let Some(relationship) = relationship {
            let replace = best_match
                .as_ref()
                .map(|current| {
                    confidence > current.2
                        || (confidence == current.2 && candidate.story_id < current.0)
                })
                .unwrap_or(true);
            if replace {
                best_match = Some((candidate.story_id.clone(), relationship, confidence));
            }
        } else if confidence >= BORDERLINE_THRESHOLD && entity_guard {
            let replace = best_borderline
                .as_ref()
                .map(|current| {
                    confidence > current.1
                        || (confidence == current.1 && candidate.story_id < current.0)
                })
                .unwrap_or(true);
            if replace {
                best_borderline = Some((candidate.story_id.clone(), confidence));
            }
        }
    }
    if let Some((story_id, membership_type, confidence)) = best_match {
        MatchDecision {
            story_id: Some(story_id),
            membership_type: Some(membership_type),
            confidence,
            borderline_story_id: None,
        }
    } else {
        MatchDecision {
            story_id: None,
            membership_type: None,
            confidence: best_borderline.as_ref().map(|item| item.1).unwrap_or(0.0),
            borderline_story_id: best_borderline.map(|item| item.0),
        }
    }
}

/// Public read-only classifier for future local/LLM arbitration. A borderline
/// decision names its candidate but intentionally has no auto-merge type.
pub fn classify_article(
    conn: &Connection,
    article: &Article,
) -> Result<MatchDecision, rusqlite::Error> {
    let event_time = article.published_at.unwrap_or(article.fetched_at);
    Ok(classify(
        &article_features(article),
        &recent_candidates(conn, event_time)?,
        event_time,
    ))
}

fn term_counts(terms: &[String]) -> BTreeMap<&str, f64> {
    let mut counts = BTreeMap::new();
    for term in terms {
        *counts.entry(term.as_str()).or_insert(0.0) += 1.0;
    }
    counts
}

fn cosine(left: &[String], right: &[String]) -> f64 {
    let left_counts = term_counts(left);
    let right_counts = term_counts(right);
    let dot: f64 = left_counts
        .iter()
        .map(|(term, count)| count * right_counts.get(term).copied().unwrap_or(0.0))
        .sum();
    let left_norm = left_counts
        .values()
        .map(|count| count * count)
        .sum::<f64>()
        .sqrt();
    let right_norm = right_counts
        .values()
        .map(|count| count * count)
        .sum::<f64>()
        .sqrt();
    if left_norm == 0.0 || right_norm == 0.0 {
        0.0
    } else {
        dot / (left_norm * right_norm)
    }
}

fn jaccard(left: &[String], right: &[String]) -> f64 {
    let left: BTreeSet<&str> = left.iter().map(String::as_str).collect();
    let right: BTreeSet<&str> = right.iter().map(String::as_str).collect();
    let union = left.union(&right).count();
    if union == 0 {
        0.0
    } else {
        left.intersection(&right).count() as f64 / union as f64
    }
}

fn overlaps(left: &[String], right: &[String]) -> bool {
    left.iter().any(|term| right.contains(term))
}

fn novelty_ratio(new: &[String], old: &[String]) -> f64 {
    let new: BTreeSet<&str> = new.iter().map(String::as_str).collect();
    if new.is_empty() {
        return 0.0;
    }
    let old: BTreeSet<&str> = old.iter().map(String::as_str).collect();
    new.difference(&old).count() as f64 / new.len() as f64
}

fn contains_update_marker(title: &str) -> bool {
    ["update", "latest", "confirmed", "now", "after"]
        .iter()
        .any(|marker| title.split_whitespace().any(|term| term == *marker))
}

fn story_seed(features: &ArticleFeatures) -> &str {
    features
        .canonical_url
        .as_deref()
        .unwrap_or(&features.normalized_title)
}

fn new_story_id(features: &ArticleFeatures, event_time: i64) -> String {
    let seed = format!(
        "{}\n{}",
        story_seed(features),
        event_time.div_euclid(ROLLING_WINDOW_SECONDS)
    );
    stable_story_id(&seed)
}

fn summary_for(article: &Article) -> String {
    article
        .content_text
        .as_deref()
        .filter(|text| !text.trim().is_empty())
        .map(|text| text.chars().take(280).collect())
        .unwrap_or_else(|| article.title.clone())
}

fn fingerprint(conn: &Connection, story_id: &str) -> Result<String, rusqlite::Error> {
    let mut statement = conn.prepare(
        "SELECT article_id FROM story_articles
         WHERE story_id = ?1 ORDER BY article_id",
    )?;
    let ids = statement
        .query_map(params![story_id], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(sha256(&ids.join("\n")))
}

fn distinct_source_count(conn: &Connection, story_id: &str) -> Result<i64, rusqlite::Error> {
    conn.query_row(
        "SELECT COUNT(DISTINCT a.feed_id)
         FROM story_articles sa
         JOIN articles a ON a.id = sa.article_id
         WHERE sa.story_id = ?1 AND sa.membership_type <> 'duplicate'",
        params![story_id],
        |row| row.get(0),
    )
}

/// Incrementally clusters an inserted article and persists membership and an
/// immutable revision. Calling it repeatedly for the same article is a no-op.
pub fn process_article(
    conn: &Connection,
    article: &Article,
) -> Result<ClusterAssignment, rusqlite::Error> {
    let transaction = conn.unchecked_transaction()?;
    let assignment = process_article_inner(&transaction, article)?;
    transaction.commit()?;
    Ok(assignment)
}

fn process_article_inner(
    conn: &Connection,
    article: &Article,
) -> Result<ClusterAssignment, rusqlite::Error> {
    if let Some(existing) = existing_assignment(conn, &article.id)? {
        return Ok(existing);
    }
    let features = article_features(article);
    cache_features(conn, article, &features)?;
    let event_time = article.published_at.unwrap_or(article.fetched_at);
    let decision = classify_article(conn, article)?;
    let created_story = decision.story_id.is_none();
    let story_id = decision
        .story_id
        .clone()
        .unwrap_or_else(|| new_story_id(&features, event_time));
    let membership_type = decision
        .membership_type
        .unwrap_or(StoryMembershipType::Coverage);
    let confidence = if created_story {
        1.0
    } else {
        decision.confidence
    };

    let existing_story = queries::get_story(conn, &story_id)?;
    let use_as_representative = existing_story
        .as_ref()
        .map(|story| {
            membership_type != StoryMembershipType::Duplicate
                && event_time >= story.last_activity_at
        })
        .unwrap_or(true);
    let title = if use_as_representative {
        article.title.clone()
    } else {
        existing_story
            .as_ref()
            .map(|story| story.title.clone())
            .unwrap_or_else(|| article.title.clone())
    };
    let summary = if use_as_representative {
        summary_for(article)
    } else {
        existing_story
            .as_ref()
            .and_then(|story| story.summary.clone())
            .unwrap_or_else(|| summary_for(article))
    };
    let representative_article_id = if use_as_representative {
        Some(article.id.clone())
    } else {
        existing_story
            .as_ref()
            .and_then(|story| story.representative_article_id.clone())
    };
    let story = Story {
        id: story_id.clone(),
        title: title.clone(),
        summary: Some(summary.clone()),
        representative_article_id: representative_article_id.clone(),
        first_seen_at: event_time,
        last_activity_at: event_time,
        created_at: existing_story
            .as_ref()
            .map(|story| story.created_at)
            .unwrap_or(article.fetched_at),
        updated_at: article.fetched_at,
    };
    queries::upsert_story(conn, &story)?;
    queries::upsert_story_article(
        conn,
        &StoryArticle {
            story_id: story_id.clone(),
            article_id: article.id.clone(),
            membership_type,
            confidence: Some(confidence),
            added_at: article.fetched_at,
        },
    )?;
    if let Some(candidate_story_id) = decision.borderline_story_id.as_deref() {
        conn.execute(
            "INSERT INTO story_borderline_matches (
                article_id, candidate_story_id, confidence, feature_version, created_at
             ) VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(article_id) DO UPDATE SET
                candidate_story_id = excluded.candidate_story_id,
                confidence = excluded.confidence,
                feature_version = excluded.feature_version,
                created_at = excluded.created_at",
            params![
                article.id,
                candidate_story_id,
                decision.confidence,
                FEATURE_VERSION,
                article.fetched_at
            ],
        )?;
    }

    let previous = queries::get_latest_story_revision(conn, &story_id)?;
    let new_fingerprint = fingerprint(conn, &story_id)?;
    if previous
        .as_ref()
        .and_then(|revision| revision.content_fingerprint.as_ref())
        != Some(&new_fingerprint)
    {
        queries::insert_story_revision(
            conn,
            &StoryRevision {
                story_id: story_id.clone(),
                revision_number: previous
                    .as_ref()
                    .map(|revision| revision.revision_number + 1)
                    .unwrap_or(1),
                title,
                summary,
                delta_summary: previous.as_ref().map(|_| {
                    match membership_type {
                        StoryMembershipType::Duplicate => {
                            "Another source published the same report."
                        }
                        StoryMembershipType::Coverage => "Additional coverage is available.",
                        StoryMembershipType::Update => "New details were reported.",
                    }
                    .to_string()
                }),
                representative_article_id,
                source_count: distinct_source_count(conn, &story_id)?.max(1),
                content_fingerprint: Some(new_fingerprint),
                is_material_change: membership_type != StoryMembershipType::Duplicate,
                created_at: article.fetched_at,
            },
        )?;
    }
    Ok(ClusterAssignment {
        story_id,
        membership_type,
        confidence,
        created_story,
        borderline_story_id: decision.borderline_story_id,
    })
}

fn existing_assignment(
    conn: &Connection,
    article_id: &str,
) -> Result<Option<ClusterAssignment>, rusqlite::Error> {
    conn.query_row(
        "SELECT story_id, membership_type, confidence
         FROM story_articles WHERE article_id = ?1",
        params![article_id],
        |row| {
            let raw: String = row.get(1)?;
            let membership_type =
                StoryMembershipType::try_from(raw.as_str()).map_err(|message| {
                    rusqlite::Error::FromSqlConversionFailure(
                        1,
                        rusqlite::types::Type::Text,
                        Box::new(std::io::Error::new(
                            std::io::ErrorKind::InvalidData,
                            message,
                        )),
                    )
                })?;
            Ok(ClusterAssignment {
                story_id: row.get(0)?,
                membership_type,
                confidence: row.get::<_, Option<f64>>(2)?.unwrap_or(1.0),
                created_story: false,
                borderline_story_id: None,
            })
        },
    )
    .optional()
}

#[derive(Debug)]
struct RankCandidate {
    story_id: String,
    score: f64,
    distinct_sources: i64,
    raw_articles: i64,
    representative_feed_id: Option<String>,
}

/// Ranks stories without rewarding repeated copies from one source. Selection
/// applies a representative-feed cap and reserves a protected singleton lane.
#[allow(dead_code)]
pub fn rank_stories(
    conn: &Connection,
    now: i64,
    limit: usize,
) -> Result<Vec<RankedStory>, rusqlite::Error> {
    if limit == 0 {
        return Ok(Vec::new());
    }
    let since = now.saturating_sub(ROLLING_WINDOW_SECONDS);
    let mut statement = conn.prepare(
        "SELECT s.id, s.last_activity_at, representative.feed_id,
                COUNT(DISTINCT CASE WHEN sa.membership_type <> 'duplicate'
                                    THEN member.feed_id END),
                COUNT(member.id),
                COALESCE(state.is_followed, 0), COALESCE(state.is_hidden, 0),
                COALESCE(SUM(CASE WHEN member.is_starred = 1 THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN interaction.feedback = 'more' THEN 1
                                  WHEN interaction.feedback = 'less' THEN -1 ELSE 0 END), 0),
                COALESCE(MAX(interaction.priority_override), 0)
         FROM stories s
         JOIN story_articles sa ON sa.story_id = s.id
         JOIN articles member ON member.id = sa.article_id
         LEFT JOIN articles representative ON representative.id = s.representative_article_id
         LEFT JOIN story_user_state state ON state.story_id = s.id
         LEFT JOIN article_interactions interaction ON interaction.article_id = member.id
         WHERE s.last_activity_at >= ?1
           AND COALESCE(state.is_hidden, 0) = 0
         GROUP BY s.id
         ORDER BY s.id",
    )?;
    let mut candidates = statement
        .query_map(params![since], |row| {
            let last_activity: i64 = row.get(1)?;
            let distinct_sources: i64 = row.get(3)?;
            let age = now.saturating_sub(last_activity).max(0) as f64;
            let recency = (1.0 - age / ROLLING_WINDOW_SECONDS as f64).max(0.0) * 4.0;
            let followed: i64 = row.get(5)?;
            let hidden: i64 = row.get(6)?;
            let starred: i64 = row.get(7)?;
            let feedback: i64 = row.get(8)?;
            let priority: i64 = row.get(9)?;
            let source_score = (distinct_sources as f64 + 1.0).ln() * 3.0;
            let preference = followed as f64 * 3.0 - hidden as f64 * 100.0
                + starred.min(2) as f64 * 0.5
                + feedback as f64
                + priority as f64 * 0.25;
            Ok(RankCandidate {
                story_id: row.get(0)?,
                score: source_score + recency + preference,
                distinct_sources,
                raw_articles: row.get(4)?,
                representative_feed_id: row.get(2)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    candidates.sort_by(|left, right| {
        right
            .score
            .partial_cmp(&left.score)
            .unwrap_or(Ordering::Equal)
            .then_with(|| left.story_id.cmp(&right.story_id))
    });

    let reserve = usize::from(limit >= 3 && candidates.iter().any(is_unique_candidate));
    let main_limit = limit.saturating_sub(reserve);
    let feed_cap = ((main_limit + 1) / 2).max(1);
    let mut feed_counts: HashMap<String, usize> = HashMap::new();
    let mut selected = Vec::new();
    let mut selected_ids = BTreeSet::new();
    for candidate in candidates.iter().filter(|item| !is_unique_candidate(item)) {
        if selected.len() >= main_limit {
            break;
        }
        let feed = candidate.representative_feed_id.as_deref().unwrap_or("");
        if feed_counts.get(feed).copied().unwrap_or(0) >= feed_cap {
            continue;
        }
        *feed_counts.entry(feed.to_string()).or_insert(0) += 1;
        selected_ids.insert(candidate.story_id.clone());
        selected.push(ranked(candidate, false));
    }
    // Relax the cap only to avoid returning a short edition.
    for candidate in candidates.iter().filter(|item| !is_unique_candidate(item)) {
        if selected.len() >= main_limit {
            break;
        }
        if selected_ids.insert(candidate.story_id.clone()) {
            selected.push(ranked(candidate, false));
        }
    }
    for candidate in candidates.iter().filter(|item| is_unique_candidate(item)) {
        if selected.len() >= limit {
            break;
        }
        if selected_ids.insert(candidate.story_id.clone()) {
            selected.push(ranked(candidate, true));
        }
    }
    // Small editions without a reservation still fill from all candidates.
    for candidate in &candidates {
        if selected.len() >= limit {
            break;
        }
        if selected_ids.insert(candidate.story_id.clone()) {
            selected.push(ranked(candidate, is_unique_candidate(candidate)));
        }
    }
    Ok(selected)
}

fn is_unique_candidate(candidate: &RankCandidate) -> bool {
    candidate.distinct_sources == 1 && candidate.raw_articles == 1
}

fn ranked(candidate: &RankCandidate, is_unique_find: bool) -> RankedStory {
    RankedStory {
        story_id: candidate.story_id.clone(),
        score: candidate.score,
        distinct_source_count: candidate.distinct_sources,
        raw_article_count: candidate.raw_articles,
        is_unique_find,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::migrations;
    use crate::db::models::{ArticleFilter, Feed, StoryUserState};

    fn setup() -> Connection {
        let conn = Connection::open_in_memory().expect("open");
        conn.execute_batch("PRAGMA foreign_keys=ON;").expect("fk");
        migrations::run_migrations(&conn).expect("migrate");
        for index in 1..=8 {
            queries::insert_feed(
                &conn,
                &Feed {
                    id: format!("feed-{index}"),
                    title: format!("Source {index}"),
                    url: format!("https://source{index}.example/feed"),
                    site_url: None,
                    description: None,
                    icon_url: None,
                    feedly_id: None,
                    created_at: 1,
                    updated_at: 1,
                    last_fetched_at: None,
                    folder_id: None,
                    opml_category: None,
                },
            )
            .expect("feed");
        }
        conn
    }

    fn article(id: &str, feed: &str, title: &str, url: &str, lead: &str, at: i64) -> Article {
        Article {
            id: id.into(),
            feed_id: feed.into(),
            title: title.into(),
            url: Some(url.into()),
            author: None,
            content_html: None,
            content_text: Some(lead.into()),
            published_at: Some(at),
            fetched_at: at,
            is_read: false,
            is_starred: false,
            feedly_entry_id: None,
        }
    }

    fn insert_and_cluster(conn: &Connection, article: &Article) -> ClusterAssignment {
        queries::insert_article(conn, article).expect("article");
        process_article(conn, article).expect("cluster")
    }

    #[test]
    fn shared_golden_normalization_and_stable_id() {
        assert_eq!(
            canonical_article_url(
                "https://Example.com:443/news/?b=2&utm_source=mail&a=1&source=rss#fragment"
            ),
            Some("https://example.com/news?a=1&b=2".into())
        );
        assert_eq!(
            normalized_story_title("Acme launches solar battery | Example News"),
            "acme launches solar battery"
        );
        assert_eq!(
            stable_story_id("https://example.com/news?a=1&b=2\n0"),
            "story-492ee725ea8735b8"
        );
    }

    #[test]
    fn exact_duplicate_collapses_without_raw_feed_leakage() {
        let conn = setup();
        let first = article(
            "a1",
            "feed-1",
            "Mars Mission Launches Successfully | Source One",
            "https://News.Example/mars/?utm_source=rss&b=2&a=1#top",
            "The Mars mission launched successfully today.",
            10_000,
        );
        let duplicate = article(
            "a2",
            "feed-2",
            "Mars Mission Launches Successfully — Source Two",
            "https://news.example/mars?a=1&b=2",
            "The Mars mission launched successfully today.",
            10_100,
        );
        let first_assignment = insert_and_cluster(&conn, &first);
        let duplicate_assignment = insert_and_cluster(&conn, &duplicate);
        assert_eq!(first_assignment.story_id, duplicate_assignment.story_id);
        assert_eq!(
            duplicate_assignment.membership_type,
            StoryMembershipType::Duplicate
        );
        let filter = ArticleFilter {
            feed_id: None,
            theme_id: None,
            is_read: None,
            is_starred: None,
            limit: Some(100),
            offset: None,
        };
        assert_eq!(queries::count_articles(&conn, &filter).unwrap(), 2);
        assert_eq!(queries::get_articles(&conn, &filter).unwrap().len(), 2);
        let ranked = rank_stories(&conn, 10_100, 1).unwrap();
        assert_eq!(ranked[0].distinct_source_count, 1);
        assert_eq!(ranked[0].raw_article_count, 2);
    }

    #[test]
    fn repeated_coverage_clusters_but_shared_company_name_does_not() {
        let conn = setup();
        let first = article(
            "a1",
            "feed-1",
            "Acme wins lunar lander contract",
            "https://one.example/acme-moon",
            "NASA selected Acme to build a lunar lander after a competitive bid.",
            20_000,
        );
        let coverage = article(
            "a2",
            "feed-2",
            "NASA selects Acme for lunar lander contract",
            "https://two.example/nasa-acme",
            "Acme was selected by NASA to build the lunar lander under a new contract.",
            20_100,
        );
        let unrelated = article(
            "a3",
            "feed-3",
            "Acme releases quarterly retail results",
            "https://three.example/acme-results",
            "Acme reported retail revenue and quarterly earnings after market close.",
            20_200,
        );
        let one = insert_and_cluster(&conn, &first);
        let two = insert_and_cluster(&conn, &coverage);
        let three = insert_and_cluster(&conn, &unrelated);
        assert_eq!(one.story_id, two.story_id);
        assert_ne!(one.story_id, three.story_id);
        assert!(matches!(
            two.membership_type,
            StoryMembershipType::Coverage | StoryMembershipType::Update
        ));
    }

    #[test]
    fn reprocessing_is_deterministic_and_does_not_add_revisions() {
        let conn = setup();
        let item = article(
            "stable",
            "feed-1",
            "Europa probe returns first images",
            "https://space.example/europa",
            "The Europa probe returned its first images.",
            30_000,
        );
        queries::insert_article(&conn, &item).unwrap();
        let first = process_article(&conn, &item).unwrap();
        let second = process_article(&conn, &item).unwrap();
        assert_eq!(first.story_id, second.story_id);
        let revisions: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM story_revisions WHERE story_id = ?1",
                params![first.story_id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(revisions, 1);
    }

    #[test]
    fn recurring_url_less_headline_outside_window_gets_new_identity() {
        let conn = setup();
        let mut early = article(
            "early",
            "feed-1",
            "Daily market briefing",
            "https://unused.example/early",
            "The morning market briefing.",
            1,
        );
        early.url = None;
        let mut later = article(
            "later",
            "feed-1",
            "Daily market briefing",
            "https://unused.example/later",
            "A later market briefing.",
            ROLLING_WINDOW_SECONDS * 2,
        );
        later.url = None;
        let early_assignment = insert_and_cluster(&conn, &early);
        let later_assignment = insert_and_cluster(&conn, &later);
        assert_ne!(early_assignment.story_id, later_assignment.story_id);
    }

    #[test]
    fn ranking_rewards_distinct_sources_and_reserves_unique_find() {
        let conn = setup();
        let now = 100_000;
        for (index, (title, lead)) in [
            (
                "Orion telescope discovers distant world",
                "The Orion telescope discovered a distant world during its latest sky survey.",
            ),
            (
                "Distant world discovered by Orion telescope",
                "Researchers using Orion found the distant world and estimated its unusual orbit.",
            ),
            (
                "Orion telescope finds distant world in new survey",
                "The Orion telescope found the distant world during a new survey and confirmed its orbit.",
            ),
        ]
        .iter()
        .enumerate()
        {
            insert_and_cluster(
                &conn,
                &article(
                    &format!("diverse-{index}"),
                    &format!("feed-{}", index + 1),
                    title,
                    &format!("https://source{}.example/orion", index + 1),
                    lead,
                    now - 100 + index as i64,
                ),
            );
        }
        for index in 0..5 {
            insert_and_cluster(
                &conn,
                &article(
                    &format!("volume-{index}"),
                    "feed-4",
                    "Local transit agency announces new timetable",
                    &format!("https://copies.example/transit/{index}"),
                    "The local transit agency announced a new timetable for bus service.",
                    now - 200 + index,
                ),
            );
        }
        let unique = insert_and_cluster(
            &conn,
            &article(
                "unique",
                "feed-8",
                "Tiny observatory spots unusual comet tail",
                "https://tiny.example/comet",
                "A small independent observatory documented an unusual comet tail.",
                now - 300,
            ),
        );
        let ranked = rank_stories(&conn, now, 3).unwrap();
        assert_eq!(ranked.len(), 3);
        assert!(ranked[0].distinct_source_count >= 3);
        assert!(ranked
            .iter()
            .any(|story| story.story_id == unique.story_id && story.is_unique_find));
        if let Some(volume) = ranked.iter().find(|story| story.raw_article_count == 5) {
            assert!(ranked[0].score > volume.score);
        }
        queries::upsert_story_user_state(
            &conn,
            &StoryUserState {
                story_id: unique.story_id.clone(),
                last_seen_revision: None,
                last_read_revision: None,
                is_followed: false,
                is_hidden: true,
                caught_up_at: None,
                updated_at: now,
            },
        )
        .unwrap();
        assert!(!rank_stories(&conn, now, 10)
            .unwrap()
            .iter()
            .any(|story| story.story_id == unique.story_id));
    }

    #[test]
    fn borderline_is_persisted_but_stays_a_separate_story() {
        let conn = setup();
        let first = article(
            "a1",
            "feed-1",
            "City council approves waterfront housing plan",
            "https://one.example/housing",
            "The city council approved a waterfront housing plan after debate.",
            40_000,
        );
        let maybe = article(
            "a2",
            "feed-2",
            "Waterfront housing plan moves forward",
            "https://two.example/housing",
            "A housing proposal on the waterfront moved forward following a public meeting.",
            40_100,
        );
        let one = insert_and_cluster(&conn, &first);
        let two = insert_and_cluster(&conn, &maybe);
        assert_ne!(one.story_id, two.story_id);
        if two.borderline_story_id.is_some() {
            let count: i64 = conn
                .query_row(
                    "SELECT COUNT(*) FROM story_borderline_matches WHERE article_id = 'a2'",
                    [],
                    |row| row.get(0),
                )
                .unwrap();
            assert_eq!(count, 1);
        }
    }
}
