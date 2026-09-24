//! Persisted finite Today editions.
//!
//! Edition snapshots are generated from the additive story index. Raw article
//! rows and the chronological feed queries remain untouched.

use super::semantic_edition::SemanticGroup;
use crate::db::models::{Edition, EditionItem, EditionStatus, StoryMembershipType, StoryRevision};
use crate::db::{queries, story_clustering};
use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;
use std::cmp::Ordering;
use std::collections::BTreeSet;

pub const SECTION_TOP_STORIES: &str = "top_stories";
pub const SECTION_WIDELY_COVERED: &str = "widely_covered";
pub const SECTION_UNIQUE_FINDS: &str = "unique_finds";
pub const SECTION_UPDATES: &str = "updates";
const SCOPE_TODAY: &str = "today";
#[cfg(test)]
const MAX_RANK_CANDIDATES: usize = 10_000;

#[derive(Debug, Clone, Serialize)]
pub struct TodayEditionMemberArticle {
    pub article_id: String,
    pub feed_id: String,
    pub feed_title: String,
    /// The feed title reduced to something printable as a byline.
    pub publication: String,
    pub feed_icon_url: Option<String>,
    pub title: String,
    pub url: Option<String>,
    pub author: Option<String>,
    pub published_at: Option<i64>,
    pub membership_type: StoryMembershipType,
    pub confidence: Option<f64>,
    pub is_representative: bool,
    /// Live interaction state may change without changing snapshot content.
    pub is_read: Option<bool>,
    pub is_starred: Option<bool>,
}

#[derive(Debug, Clone, Serialize)]
pub struct TodayEditionItemView {
    #[serde(flatten)]
    pub snapshot: EditionItem,
    pub has_material_update: bool,
    pub representative_article_id: Option<String>,
    pub member_article_ids: Vec<String>,
    pub member_articles: Vec<TodayEditionMemberArticle>,
}

#[derive(Debug, Clone, Serialize)]
pub struct TodayEditionView {
    pub edition: Edition,
    pub items: Vec<TodayEditionItemView>,
    pub consumed_count: i64,
    pub total_count: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct Candidate {
    rank: story_clustering::RankedStory,
    revision: StoryRevision,
    is_update: bool,
    constituents: Vec<(String, i64)>,
    semantic_reason: Option<String>,
    timestamp: i64,
    evidence: String,
    sources: Vec<MemberSnapshot>,
}

#[derive(Debug, Clone, Serialize)]
struct MemberSnapshot {
    article_id: String,
    feed_id: String,
    feed_title: String,
    feed_icon_url: Option<String>,
    title: String,
    url: Option<String>,
    author: Option<String>,
    published_at: Option<i64>,
    membership_type: StoryMembershipType,
    confidence: Option<f64>,
    is_representative: bool,
}

/// Stable across devices and retries for an explicit local-day window and cap.
pub fn edition_id(starts_at: i64, ends_at: i64, story_limit: i64) -> String {
    format!("today-{starts_at}-{ends_at}-{story_limit}")
}

#[cfg(test)]
pub fn get_or_generate(
    conn: &Connection,
    starts_at: i64,
    ends_at: i64,
    generated_at: i64,
    story_limit: i64,
) -> Result<TodayEditionView, rusqlite::Error> {
    validate_window_and_limit(starts_at, ends_at, generated_at, story_limit)?;
    let id = edition_id(starts_at, ends_at, story_limit);
    if queries::get_edition(conn, &id)?.is_some() {
        let existing = load(conn, &id)?;
        if !existing.items.is_empty() {
            return Ok(existing);
        }
    }
    generate(conn, &id, starts_at, ends_at, generated_at, story_limit)?;
    load(conn, &id)
}

pub(crate) fn validate_window_and_limit(
    starts_at: i64,
    ends_at: i64,
    generated_at: i64,
    story_limit: i64,
) -> Result<(), rusqlite::Error> {
    if ends_at <= starts_at {
        return Err(rusqlite::Error::InvalidParameterName(
            "Today edition ends_at must be after starts_at".into(),
        ));
    }
    if generated_at < starts_at || generated_at >= ends_at {
        return Err(rusqlite::Error::InvalidParameterName(
            "Today edition generated_at must be inside its explicit day window".into(),
        ));
    }
    if !matches!(story_limit, 5 | 10 | 20) {
        return Err(rusqlite::Error::InvalidParameterName(
            "Today edition story_limit must be 5, 10, or 20".into(),
        ));
    }
    Ok(())
}

pub fn collect_candidates(
    conn: &Connection,
    starts_at: i64,
    ends_at: i64,
    generated_at: i64,
    story_limit: i64,
) -> Result<Vec<Candidate>, rusqlite::Error> {
    validate_window_and_limit(starts_at, ends_at, generated_at, story_limit)?;
    let mut ranked = story_clustering::rank_stories(
        conn,
        generated_at,
        conn.query_row("SELECT COUNT(*) FROM stories", [], |row| {
            row.get::<_, i64>(0)
        })? as usize,
    )?;
    ranked.sort_by(|left, right| {
        right
            .score
            .partial_cmp(&left.score)
            .unwrap_or(Ordering::Equal)
            .then_with(|| left.story_id.cmp(&right.story_id))
    });
    let mut candidates = Vec::with_capacity(ranked.len());
    for rank in ranked {
        let Some(story) = queries::get_story(conn, &rank.story_id)? else {
            continue;
        };
        if story.last_activity_at < starts_at || story.last_activity_at >= ends_at {
            continue;
        }
        let Some(revision) = queries::get_latest_story_revision(conn, &rank.story_id)? else {
            continue;
        };
        // A new syndicated copy can advance activity without adding news.
        // Keep prior-day consumed stories off the page until a material revision
        // arrives. Existing editions return before generation and stay frozen.
        let already_consumed_without_update: bool = conn.query_row(
            "SELECT EXISTS (
                SELECT 1 FROM edition_items consumed
                JOIN editions previous ON previous.id = consumed.edition_id
                JOIN edition_item_story_revisions member ON member.edition_id = consumed.edition_id AND member.item_story_id = consumed.story_id
                WHERE member.member_story_id = ?1 AND consumed.is_consumed = 1
                  AND previous.ends_at <= ?2
                  AND NOT EXISTS (
                    SELECT 1 FROM story_revisions revision
                    WHERE revision.story_id = ?1
                      AND revision.revision_number > member.revision_number
                      AND revision.is_material_change = 1
                  )
            )",
            params![rank.story_id, starts_at],
            |row| row.get(0),
        )?;
        if already_consumed_without_update {
            continue;
        }
        let memberships = queries::list_story_articles(conn, &rank.story_id)?;
        let is_update = memberships
            .iter()
            .any(|membership| membership.membership_type == StoryMembershipType::Update);
        let evidence = revision.representative_article_id.as_deref()
            .map(|id| queries::get_article_by_id(conn, id)).transpose()?.flatten()
            .and_then(|article| article.article.content_text)
            .filter(|text| !text.trim().is_empty())
            .unwrap_or_else(|| revision.summary.clone())
            .chars().take(super::story_policy::semantic_evidence_characters()).collect();
        candidates.push(Candidate {
            evidence,
            timestamp: story.last_activity_at,
            sources: member_snapshots(
                conn,
                &rank.story_id,
                revision.representative_article_id.as_deref(),
            )?,
            constituents: vec![(rank.story_id.clone(), revision.revision_number)],
            semantic_reason: None,
            rank,
            revision,
            is_update,
        });
    }

    Ok(candidates)
}

pub fn semantic_listing(candidates: &[Candidate]) -> String {
    serde_json::to_string(
        &candidates
            .iter()
            .enumerate()
            .map(|(index, candidate)| {
                serde_json::json!({
                    "index": index,
                    "title": candidate.revision.title.chars().take(240).collect::<String>(),
                    "excerpt": candidate.revision.summary.chars().take(240).collect::<String>(),
                    "timestamp": candidate.timestamp as f64,
                    "baseScore": candidate.rank.score,
                    "evidence": candidate.evidence
                })
            })
            .collect::<Vec<_>>(),
    )
    .expect("serializable semantic inputs")
}

pub fn candidate_fingerprint(candidates: &[Candidate]) -> String {
    serde_json::to_string(candidates).expect("serializable candidates")
}

pub fn frozen(conn: &Connection, id: &str) -> Result<Option<TodayEditionView>, rusqlite::Error> {
    if queries::get_edition(conn, id)?.is_some() {
        let view = load(conn, id)?;
        if !view.items.is_empty() {
            return Ok(Some(view));
        }
    }
    Ok(None)
}

pub fn finish_semantic(
    conn: &Connection,
    starts_at: i64,
    ends_at: i64,
    generated_at: i64,
    story_limit: i64,
    fingerprint: &str,
    groups: Option<Vec<SemanticGroup>>,
) -> Result<TodayEditionView, rusqlite::Error> {
    let id = edition_id(starts_at, ends_at, story_limit);
    if let Some(view) = frozen(conn, &id)? {
        return Ok(view);
    }
    let transaction = conn.unchecked_transaction()?;
    let candidates =
        collect_candidates(&transaction, starts_at, ends_at, generated_at, story_limit)?;
    let groups = if candidate_fingerprint(&candidates) == fingerprint {
        groups
    } else {
        None
    };
    persist_candidates(
        &transaction,
        &id,
        starts_at,
        ends_at,
        generated_at,
        story_limit,
        candidates,
        groups,
    )?;
    transaction.commit()?;
    load(conn, &id)
}

#[cfg(test)]
fn generate(
    conn: &Connection,
    id: &str,
    starts_at: i64,
    ends_at: i64,
    generated_at: i64,
    story_limit: i64,
) -> Result<(), rusqlite::Error> {
    let transaction = conn.unchecked_transaction()?;
    let candidates =
        collect_candidates(&transaction, starts_at, ends_at, generated_at, story_limit)?;
    persist_candidates(
        &transaction,
        id,
        starts_at,
        ends_at,
        generated_at,
        story_limit,
        candidates,
        None,
    )?;
    transaction.commit()
}

fn persist_candidates(
    conn: &Connection,
    id: &str,
    starts_at: i64,
    ends_at: i64,
    generated_at: i64,
    story_limit: i64,
    mut candidates: Vec<Candidate>,
    groups: Option<Vec<SemanticGroup>>,
) -> Result<(), rusqlite::Error> {
    let semantic = groups.as_ref().is_some_and(|groups| !groups.is_empty());
    if let Some(groups) = groups {
        let mut used = BTreeSet::new();
        let mut grouped = Vec::new();
        for group in groups {
            let mut indices = group.members.clone();
            indices.sort_by(|a, b| {
                candidates[*b]
                    .rank
                    .score
                    .partial_cmp(&candidates[*a].rank.score)
                    .unwrap_or(Ordering::Equal)
                    .then_with(|| {
                        candidates[*a]
                            .rank
                            .story_id
                            .cmp(&candidates[*b].rank.story_id)
                    })
            });
            let mut anchor = candidates[indices[0]].clone();
            anchor.rank.score = super::story_policy::semantic_score(
                anchor.rank.score,
                group.importance,
                group.confidence,
            );
            anchor.constituents.clear();
            anchor.sources.clear();
            anchor.semantic_reason = Some(group.reason);
            for index in indices {
                used.insert(index);
                anchor
                    .constituents
                    .extend(candidates[index].constituents.clone());
                anchor.is_update |= candidates[index].is_update;
                anchor.sources.extend(candidates[index].sources.clone());
            }
            let mut article_ids = BTreeSet::new();
            anchor
                .sources
                .retain(|source| article_ids.insert(source.article_id.clone()));
            for source in &mut anchor.sources {
                source.is_representative =
                    Some(&source.article_id) == anchor.revision.representative_article_id.as_ref();
            }
            grouped.push(anchor);
        }
        grouped.extend(
            candidates
                .into_iter()
                .enumerate()
                .filter(|(index, _)| !used.contains(index))
                .map(|(_, candidate)| candidate),
        );
        candidates = grouped;
        candidates.sort_by(|a, b| {
            b.rank
                .score
                .partial_cmp(&a.rank.score)
                .unwrap_or(Ordering::Equal)
                .then_with(|| a.rank.story_id.cmp(&b.rank.story_id))
        });
    }

    let mut selected = if semantic {
        candidates.iter().take(story_limit as usize).collect()
    } else {
        select_candidates(&candidates, story_limit as usize)
    };
    // A front page runs in order of importance. Ordering by section put every
    // story that no second outlet happened to cover — in practice almost all
    // of them — into one undifferentiated block at the bottom of the page.
    // Section stays on each item as metadata; it no longer decides position.
    selected.sort_by(|left, right| {
        right
            .rank
            .score
            .partial_cmp(&left.rank.score)
            .unwrap_or(Ordering::Equal)
            .then_with(|| left.rank.story_id.cmp(&right.rank.story_id))
    });
    let selected_with_members = selected
        .iter()
        .map(|candidate| (*candidate, candidate.sources.clone()))
        .collect::<Vec<_>>();
    let total_source_count = selected_with_members
        .iter()
        .flat_map(|(_, members)| members)
        .filter(|member| member.membership_type != StoryMembershipType::Duplicate)
        .map(|member| member.feed_id.as_str())
        .collect::<BTreeSet<_>>()
        .len() as i64;
    let is_empty = selected_with_members.is_empty();
    let edition = Edition {
        id: id.into(),
        title: "Today".into(),
        scope: SCOPE_TODAY.into(),
        story_limit,
        status: if is_empty {
            EditionStatus::Completed
        } else {
            EditionStatus::Ready
        },
        starts_at,
        ends_at,
        generated_at,
        completed_at: is_empty.then_some(generated_at),
        total_source_count,
    };
    let transaction = conn;
    // Empty placeholders can recover after feed refresh. Recheck in the same
    // transaction as replacement; never overwrite a populated frozen edition.
    if queries::get_edition(&transaction, id)?.is_some() {
        let has_items: bool = transaction.query_row(
            "SELECT EXISTS (SELECT 1 FROM edition_items WHERE edition_id = ?1)",
            params![id],
            |row| row.get(0),
        )?;
        if has_items || is_empty {
            return Ok(());
        }
        transaction.execute("DELETE FROM editions WHERE id = ?1", params![id])?;
    }
    queries::insert_edition(&transaction, &edition)?;
    for (position, (candidate, members)) in selected_with_members.iter().enumerate() {
        let source_count = members
            .iter()
            .filter(|member| member.membership_type != StoryMembershipType::Duplicate)
            .map(|member| &member.feed_id)
            .collect::<BTreeSet<_>>()
            .len()
            .max(1) as i64;
        let section = if candidate.constituents.len() > 1 {
            if candidate.is_update {
                SECTION_UPDATES
            } else {
                SECTION_TOP_STORIES
            }
        } else {
            section_for(candidate)
        };
        transaction.execute(
            "INSERT INTO edition_items (
                edition_id, story_id, story_revision_number, position, section,
                snapshot_title, snapshot_summary, snapshot_delta_summary,
                snapshot_source_count, snapshot_reason, is_unique_find,
                is_consumed, consumed_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, 0, NULL)",
            params![
                edition.id,
                candidate.rank.story_id,
                candidate.revision.revision_number,
                position as i64,
                section,
                candidate.revision.title,
                candidate.revision.summary,
                candidate.revision.delta_summary,
                source_count,
                candidate
                    .semantic_reason
                    .clone()
                    .unwrap_or_else(|| reason_for(section, source_count)),
                (source_count == 1) as i32,
            ],
        )?;
    }
    for (candidate, members) in &selected_with_members {
        for (member_story_id, revision_number) in &candidate.constituents {
            transaction.execute("INSERT INTO edition_item_story_revisions (edition_id, item_story_id, member_story_id, revision_number) VALUES (?1, ?2, ?3, ?4)", params![id, candidate.rank.story_id, member_story_id, revision_number])?;
        }
        for (snapshot_order, member) in members.iter().enumerate() {
            transaction.execute(
                "INSERT INTO edition_item_articles (
                    edition_id, story_id, article_id, feed_id,
                    snapshot_feed_title, snapshot_feed_icon_url,
                    snapshot_article_title, snapshot_article_url, snapshot_author,
                    snapshot_published_at, membership_type, confidence,
                    snapshot_order, is_representative
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)",
                params![
                    edition.id,
                    candidate.rank.story_id,
                    member.article_id,
                    member.feed_id,
                    member.feed_title,
                    member.feed_icon_url,
                    member.title,
                    member.url,
                    member.author,
                    member.published_at,
                    member.membership_type.as_str(),
                    member.confidence,
                    snapshot_order as i64,
                    member.is_representative as i32,
                ],
            )?;
        }
    }
    Ok(())
}

fn select_candidates(candidates: &[Candidate], limit: usize) -> Vec<&Candidate> {
    let mut selected_ids = BTreeSet::new();
    // Reserve scarce roles before rank-filling the remainder.
    for candidate in [
        candidates.iter().find(|candidate| candidate.is_update),
        candidates
            .iter()
            .find(|candidate| candidate.rank.is_unique_find),
        candidates
            .iter()
            .find(|candidate| candidate.rank.distinct_source_count >= 3),
    ]
    .into_iter()
    .flatten()
    {
        if selected_ids.len() < limit {
            selected_ids.insert(candidate.rank.story_id.as_str());
        }
    }
    for candidate in candidates {
        if selected_ids.len() >= limit {
            break;
        }
        selected_ids.insert(candidate.rank.story_id.as_str());
    }
    candidates
        .iter()
        .filter(|candidate| selected_ids.contains(candidate.rank.story_id.as_str()))
        .take(limit)
        .collect()
}

fn section_for(candidate: &Candidate) -> &'static str {
    if candidate.is_update {
        SECTION_UPDATES
    } else if candidate.rank.is_unique_find {
        SECTION_UNIQUE_FINDS
    } else if candidate.rank.distinct_source_count >= 3 {
        SECTION_WIDELY_COVERED
    } else {
        SECTION_TOP_STORIES
    }
}

fn reason_for(section: &str, source_count: i64) -> String {
    match section {
        SECTION_UPDATES => "updated_story".into(),
        SECTION_UNIQUE_FINDS => "unique_singleton".into(),
        SECTION_WIDELY_COVERED => format!("widely_covered:{source_count}"),
        _ => "high_rank_recent".into(),
    }
}

fn member_snapshots(
    conn: &Connection,
    story_id: &str,
    representative_article_id: Option<&str>,
) -> Result<Vec<MemberSnapshot>, rusqlite::Error> {
    let mut statement = conn.prepare(
        "SELECT a.id, a.feed_id, f.title, f.icon_url, a.title, a.url,
                a.author, a.published_at, sa.membership_type, sa.confidence
         FROM story_articles sa
         JOIN articles a ON a.id = sa.article_id
         JOIN feeds f ON f.id = a.feed_id
         WHERE sa.story_id = ?1
         ORDER BY CASE WHEN a.id = ?2 THEN 0 ELSE 1 END,
                  COALESCE(a.published_at, a.fetched_at) DESC, a.id",
    )?;
    let members = statement
        .query_map(params![story_id, representative_article_id], |row| {
            let article_id: String = row.get(0)?;
            Ok(MemberSnapshot {
                is_representative: representative_article_id == Some(article_id.as_str()),
                article_id,
                feed_id: row.get(1)?,
                feed_title: row.get(2)?,
                feed_icon_url: row.get(3)?,
                title: row.get(4)?,
                url: row.get(5)?,
                author: row.get(6)?,
                published_at: row.get(7)?,
                membership_type: membership_type_from_raw(row.get(8)?, 8)?,
                confidence: row.get(9)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(members)
}

fn membership_type_from_raw(
    raw: String,
    index: usize,
) -> Result<StoryMembershipType, rusqlite::Error> {
    StoryMembershipType::try_from(raw.as_str()).map_err(|message| {
        rusqlite::Error::FromSqlConversionFailure(
            index,
            rusqlite::types::Type::Text,
            Box::new(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                message,
            )),
        )
    })
}

pub fn load(conn: &Connection, edition_id: &str) -> Result<TodayEditionView, rusqlite::Error> {
    let edition =
        queries::get_edition(conn, edition_id)?.ok_or(rusqlite::Error::QueryReturnedNoRows)?;
    let items = list_items(conn, edition_id)?;
    let consumed_count = items
        .iter()
        .filter(|item| item.snapshot.is_consumed)
        .count() as i64;
    let total_count = items.len() as i64;
    Ok(TodayEditionView {
        edition,
        items,
        consumed_count,
        total_count,
    })
}

pub fn list_items(
    conn: &Connection,
    edition_id: &str,
) -> Result<Vec<TodayEditionItemView>, rusqlite::Error> {
    queries::list_edition_items(conn, edition_id)?
        .into_iter()
        .map(|snapshot| {
            let representative_article_id = conn
                .query_row(
                    "SELECT article_id FROM edition_item_articles
                     WHERE edition_id = ?1 AND story_id = ?2 AND is_representative = 1
                     ORDER BY snapshot_order LIMIT 1",
                    params![snapshot.edition_id, snapshot.story_id],
                    |row| row.get(0),
                )
                .optional()?;
            let member_articles =
                list_snapshot_member_articles(conn, &snapshot.edition_id, &snapshot.story_id)?;
            let member_article_ids = member_articles
                .iter()
                .map(|member| member.article_id.clone())
                .collect();
            let has_material_update = queries::get_story_revision(
                conn, &snapshot.story_id, snapshot.story_revision_number,
            )?.is_some_and(|revision| revision.is_material_change);
            Ok(TodayEditionItemView {
                has_material_update,
                snapshot,
                representative_article_id,
                member_article_ids,
                member_articles,
            })
        })
        .collect()
}

fn list_snapshot_member_articles(
    conn: &Connection,
    edition_id: &str,
    story_id: &str,
) -> Result<Vec<TodayEditionMemberArticle>, rusqlite::Error> {
    let mut statement = conn.prepare(
        "SELECT snapshot.article_id, snapshot.feed_id,
                snapshot.snapshot_feed_title, snapshot.snapshot_feed_icon_url,
                snapshot.snapshot_article_title, snapshot.snapshot_article_url,
                snapshot.snapshot_author, snapshot.snapshot_published_at,
                snapshot.membership_type, snapshot.confidence,
                snapshot.is_representative, live.is_read, live.is_starred
         FROM edition_item_articles snapshot
         LEFT JOIN articles live ON live.id = snapshot.article_id
         WHERE snapshot.edition_id = ?1 AND snapshot.story_id = ?2
         ORDER BY snapshot.snapshot_order",
    )?;
    let members = statement
        .query_map(params![edition_id, story_id], |row| {
            let feed_title: String = row.get(2)?;
            let url: Option<String> = row.get(5)?;
            Ok(TodayEditionMemberArticle {
                article_id: row.get(0)?,
                feed_id: row.get(1)?,
                publication: crate::ai::publication::publication_name(&feed_title, url.as_deref()),
                feed_title,
                feed_icon_url: row.get(3)?,
                title: row.get(4)?,
                url,
                author: row.get(6)?,
                published_at: row.get(7)?,
                membership_type: membership_type_from_raw(row.get(8)?, 8)?,
                confidence: row.get(9)?,
                is_representative: row.get::<_, i32>(10)? != 0,
                is_read: row.get::<_, Option<i32>>(11)?.map(|value| value != 0),
                is_starred: row.get::<_, Option<i32>>(12)?.map(|value| value != 0),
            })
        })?
        .collect();
    members
}

pub fn set_item_consumed(
    conn: &Connection,
    edition_id: &str,
    story_id: &str,
    is_consumed: bool,
    changed_at: i64,
) -> Result<TodayEditionView, rusqlite::Error> {
    let transaction = conn.unchecked_transaction()?;
    let changed = queries::set_edition_item_consumed(
        &transaction,
        edition_id,
        story_id,
        is_consumed,
        is_consumed.then_some(changed_at),
    )?;
    if !changed {
        return Err(rusqlite::Error::QueryReturnedNoRows);
    }
    if is_consumed {
        transaction.execute(
            "UPDATE articles SET is_read = 1
             WHERE id IN (
                SELECT article_id FROM edition_item_articles
                WHERE edition_id = ?1 AND story_id = ?2
             )",
            params![edition_id, story_id],
        )?;
    }
    let (consumed_count, total_count): (i64, i64) = transaction.query_row(
        "SELECT COALESCE(SUM(is_consumed), 0), COUNT(*)
         FROM edition_items WHERE edition_id = ?1",
        params![edition_id],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    let completed = total_count > 0 && consumed_count == total_count;
    queries::update_edition_progress(
        &transaction,
        edition_id,
        if completed {
            EditionStatus::Completed
        } else {
            EditionStatus::Ready
        },
        completed.then_some(changed_at),
        queries::get_edition(&transaction, edition_id)?
            .ok_or(rusqlite::Error::QueryReturnedNoRows)?
            .total_source_count,
    )?;
    transaction.commit()?;
    load(conn, edition_id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::migrations;
    use crate::db::models::{
        Article, ArticleFilter, Feed, Story, StoryArticle, StoryMembershipType, StoryRevision,
    };

    const DAY_START: i64 = 1_728_000;
    const DAY_END: i64 = DAY_START + 86_400;
    const GENERATED_AT: i64 = DAY_START + 43_200;

    fn setup_empty() -> Connection {
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

    fn setup() -> Connection {
        let conn = setup_empty();
        add_story(&conn, "wide", 3, false, GENERATED_AT - 10);
        add_story(&conn, "update", 2, true, GENERATED_AT - 20);
        add_story(&conn, "unique", 1, false, GENERATED_AT - 30);
        add_story(&conn, "top-a", 2, false, GENERATED_AT - 40);
        add_story(&conn, "top-b", 2, false, GENERATED_AT - 50);
        add_story(&conn, "top-c", 2, false, GENERATED_AT - 60);
        add_story(&conn, "top-d", 2, false, GENERATED_AT - 70);
        add_story(&conn, "prior-day", 3, false, DAY_START - 100);
        conn
    }

    fn add_story(
        conn: &Connection,
        story_id: &str,
        source_count: usize,
        has_update: bool,
        at: i64,
    ) {
        let mut article_ids = Vec::new();
        for source in 1..=source_count {
            let article_id = format!("{story_id}-article-{source}");
            article_ids.push(article_id.clone());
            queries::insert_article(
                conn,
                &Article {
                    id: article_id,
                    feed_id: format!("feed-{source}"),
                    title: format!("{story_id} report {source}"),
                    url: Some(format!(
                        "https://source{source}.example/{story_id}/{source}"
                    )),
                    author: None,
                    content_html: None,
                    content_text: Some(format!("Coverage of {story_id} from source {source}.")),
                    published_at: Some(at + source as i64),
                    fetched_at: at + source as i64,
                    is_read: false,
                    is_starred: false,
                    feedly_entry_id: None,
                    comments_url: None,
                },
            )
            .expect("article");
        }
        let representative = article_ids.last().cloned();
        queries::upsert_story(
            conn,
            &Story {
                id: story_id.into(),
                title: format!("{story_id} snapshot"),
                summary: Some(format!("Summary for {story_id}")),
                representative_article_id: representative.clone(),
                first_seen_at: at,
                last_activity_at: at + source_count as i64,
                created_at: at,
                updated_at: at,
            },
        )
        .expect("story");
        for (index, article_id) in article_ids.iter().enumerate() {
            queries::upsert_story_article(
                conn,
                &StoryArticle {
                    story_id: story_id.into(),
                    article_id: article_id.clone(),
                    membership_type: if has_update && index + 1 == source_count {
                        StoryMembershipType::Update
                    } else {
                        StoryMembershipType::Coverage
                    },
                    confidence: Some(0.9),
                    added_at: at + index as i64,
                },
            )
            .expect("membership");
        }
        queries::insert_story_revision(
            conn,
            &StoryRevision {
                story_id: story_id.into(),
                revision_number: if has_update { 2 } else { 1 },
                title: format!("{story_id} snapshot"),
                summary: format!("Summary for {story_id}"),
                delta_summary: has_update.then(|| "New confirmed detail.".into()),
                representative_article_id: representative,
                source_count: source_count as i64,
                content_fingerprint: Some(format!("fingerprint-{story_id}")),
                is_material_change: has_update,
                created_at: at,
            },
        )
        .expect("revision");
    }

    #[test]
    fn material_update_flag_uses_frozen_revision_not_later_revisions() {
        let conn = setup_empty();
        add_story(&conn, "duplicate", 1, false, GENERATED_AT - 10);
        add_story(&conn, "material", 1, true, GENERATED_AT - 9);
        let mut duplicate = queries::get_latest_story_revision(&conn, "duplicate").unwrap().unwrap();
        duplicate.revision_number += 1;
        duplicate.delta_summary = Some("Another source published the same report".into());
        queries::insert_story_revision(&conn, &duplicate).unwrap();
        let edition = get_or_generate(&conn, DAY_START, DAY_END, GENERATED_AT, 5).unwrap();
        for item in &edition.items {
            assert_eq!(item.has_material_update, item.snapshot.story_id == "material");
            assert!(item.snapshot.snapshot_delta_summary.is_some());
            let mut later = queries::get_latest_story_revision(&conn, &item.snapshot.story_id).unwrap().unwrap();
            later.revision_number += 1;
            later.is_material_change = !later.is_material_change;
            later.delta_summary = Some("A later revision must not change the frozen card".into());
            queries::insert_story_revision(&conn, &later).unwrap();
        }
        let reloaded = load(&conn, &edition.edition.id).unwrap();
        assert_eq!(reloaded.items.len(), 2);
        for item in reloaded.items {
            let frozen = edition.items.iter().find(|old| old.snapshot.story_id == item.snapshot.story_id).unwrap();
            assert_eq!(item.has_material_update, frozen.has_material_update);
            assert_eq!(item.snapshot.story_revision_number, frozen.snapshot.story_revision_number);
            assert_eq!(item.snapshot.snapshot_delta_summary, frozen.snapshot.snapshot_delta_summary);
        }
    }

    #[test]
    fn semantic_json_matches_native_fields_and_limits() {
        let conn = setup();
        let mut candidates =
            collect_candidates(&conn, DAY_START, DAY_END, GENERATED_AT, 5).unwrap();
        candidates[0].revision.title = "界".repeat(300);
        candidates[0].revision.summary = "é".repeat(300);
        let value: serde_json::Value =
            serde_json::from_str(&semantic_listing(&candidates)).unwrap();
        let first = &value[0];
        assert_eq!(first.as_object().unwrap().len(), 6);
        assert_eq!(first["index"], 0);
        assert_eq!(first["title"].as_str().unwrap().chars().count(), 240);
        assert_eq!(first["excerpt"].as_str().unwrap().chars().count(), 240);
        assert_eq!(
            first["timestamp"].as_f64(),
            Some(candidates[0].timestamp as f64)
        );
        assert_eq!(first["baseScore"].as_f64(), Some(candidates[0].rank.score));
    }

    #[test]
    fn representative_body_evidence_is_bounded_and_invalidates_stale_plan() {
        let conn = setup_empty();
        add_story(&conn, "first", 1, false, GENERATED_AT - 20);
        add_story(&conn, "second", 1, false, GENERATED_AT - 10);
        let body = format!("{}The permit was denied, not granted. {}", "Context. ".repeat(40), "界".repeat(2500));
        conn.execute("UPDATE articles SET content_text = ?1 WHERE id = 'first-article-1'", [&body]).unwrap();
        let candidates = collect_candidates(&conn, DAY_START, DAY_END, GENERATED_AT, 5).unwrap();
        let candidate = candidates.iter().find(|c| c.rank.story_id == "first").unwrap();
        assert!(candidate.evidence.contains("permit was denied"));
        assert_eq!(candidate.evidence.chars().count(), 2048);
        let fingerprint = candidate_fingerprint(&candidates);
        conn.execute("UPDATE articles SET content_text = 'Changed underlying evidence' WHERE id = 'first-article-1'", []).unwrap();
        let groups = super::super::semantic_edition::parse(r#"{"groups":[{"members":[0,1],"importance":5,"confidence":1,"reason":"same event"}]}"#, 2);
        let edition = finish_semantic(&conn, DAY_START, DAY_END, GENERATED_AT, 5, &fingerprint, groups).unwrap();
        assert_eq!(edition.items.len(), 2, "stale evidence must discard merge");
        conn.execute("UPDATE articles SET content_text = ' ' WHERE id = 'first-article-1'", []).unwrap();
        let fresh = collect_candidates(&conn, DAY_START, DAY_END, GENERATED_AT, 5).unwrap();
        let candidate = fresh.iter().find(|c| c.rank.story_id == "first").unwrap();
        assert_eq!(candidate.evidence, candidate.revision.summary);
        assert_eq!(frozen(&conn, &edition.edition.id).unwrap().unwrap().items.len(), 2);
    }

    #[test]
    fn semantic_source_replacement_race_discards_plan() {
        let conn = setup_empty();
        add_story(&conn, "first", 1, false, GENERATED_AT - 20);
        add_story(&conn, "second", 1, false, GENERATED_AT - 10);
        let candidates = collect_candidates(&conn, DAY_START, DAY_END, GENERATED_AT, 5).unwrap();
        // Same feed, count, rank and frozen revision; only the live source changes.
        conn.execute("UPDATE articles SET title = 'Replacement source report', url = 'https://source1.example/replacement' WHERE id = 'second-article-1'", []).unwrap();
        let groups = super::super::semantic_edition::parse(
            r#"{"groups":[{"members":[0,1],"importance":5,"confidence":1,"reason":"same event"}]}"#,
            2,
        );
        let result = finish_semantic(
            &conn,
            DAY_START,
            DAY_END,
            GENERATED_AT,
            5,
            &candidate_fingerprint(&candidates),
            groups,
        )
        .unwrap();
        assert_eq!(result.items.len(), 2);
        assert!(result
            .items
            .iter()
            .flat_map(|item| &item.member_articles)
            .any(|source| source.title == "Replacement source report"));
    }

    #[test]
    fn semantic_groups_freeze_all_references_and_consume_every_constituent() {
        let conn = setup_empty();
        add_story(&conn, "first", 2, false, GENERATED_AT - 20);
        add_story(&conn, "second", 1, false, GENERATED_AT - 10);
        let candidates = collect_candidates(&conn, DAY_START, DAY_END, GENERATED_AT, 5).unwrap();
        let groups = super::super::semantic_edition::parse(
            r#"{"groups":[{"members":[0,1],"importance":5,"confidence":0.95,"reason":"Reports describe the same event"}]}"#,
            2,
        );
        let grouped = finish_semantic(
            &conn,
            DAY_START,
            DAY_END,
            GENERATED_AT,
            5,
            &candidate_fingerprint(&candidates),
            groups,
        )
        .unwrap();
        assert_eq!(grouped.items.len(), 1);
        assert_eq!(grouped.items[0].member_article_ids.len(), 3);
        assert_eq!(
            conn.query_row(
                "SELECT COUNT(*) FROM edition_item_story_revisions",
                [],
                |row| row.get::<_, i64>(0)
            )
            .unwrap(),
            2
        );
        let frozen = serde_json::to_string(&grouped).unwrap();
        assert_eq!(
            serde_json::to_string(
                &get_or_generate(&conn, DAY_START, DAY_END, GENERATED_AT + 1, 5).unwrap()
            )
            .unwrap(),
            frozen
        );
        let anchor = &grouped.items[0].snapshot.story_id;
        set_item_consumed(&conn, &grouped.edition.id, anchor, true, GENERATED_AT + 1).unwrap();
        assert_eq!(
            conn.query_row(
                "SELECT COUNT(*) FROM articles WHERE is_read = 1",
                [],
                |row| row.get::<_, i64>(0)
            )
            .unwrap(),
            3
        );
        conn.execute("UPDATE stories SET last_activity_at = ?1", [DAY_END + 10])
            .unwrap();
        assert!(
            collect_candidates(&conn, DAY_END, DAY_END + 86400, DAY_END + 100, 5)
                .unwrap()
                .is_empty()
        );
        let mut revision = queries::get_latest_story_revision(&conn, "second")
            .unwrap()
            .unwrap();
        revision.revision_number += 1;
        revision.is_material_change = true;
        revision.content_fingerprint = Some("material-change".into());
        queries::insert_story_revision(&conn, &revision).unwrap();
        let next = collect_candidates(&conn, DAY_END, DAY_END + 86400, DAY_END + 100, 5).unwrap();
        assert_eq!(next.len(), 1);
        assert_eq!(next[0].rank.story_id, "second");
        assert_eq!(
            load(&conn, &grouped.edition.id).unwrap().items[0]
                .member_article_ids
                .len(),
            3
        );
    }

    #[test]
    fn semantic_revision_race_falls_back_and_invalid_groups_omit_nothing() {
        let conn = setup_empty();
        add_story(&conn, "first", 1, false, GENERATED_AT - 20);
        add_story(&conn, "second", 1, false, GENERATED_AT - 10);
        let candidates = collect_candidates(&conn, DAY_START, DAY_END, GENERATED_AT, 5).unwrap();
        let mut revision = queries::get_latest_story_revision(&conn, "first")
            .unwrap()
            .unwrap();
        revision.revision_number += 1;
        revision.is_material_change = true;
        queries::insert_story_revision(&conn, &revision).unwrap();
        let groups = super::super::semantic_edition::parse(
            r#"{"groups":[{"members":[0,1],"importance":5,"confidence":1,"reason":"same"}]}"#,
            2,
        );
        let result = finish_semantic(
            &conn,
            DAY_START,
            DAY_END,
            GENERATED_AT,
            5,
            &candidate_fingerprint(&candidates),
            groups,
        )
        .unwrap();
        assert_eq!(result.items.len(), 2);
        assert_eq!(
            result
                .items
                .iter()
                .map(|item| item.member_article_ids.len())
                .sum::<usize>(),
            2
        );
        conn.execute("DELETE FROM edition_item_story_revisions", [])
            .unwrap();
        migrations::run_migrations(&conn).unwrap();
        assert_eq!(
            conn.query_row(
                "SELECT COUNT(*) FROM edition_item_story_revisions",
                [],
                |row| row.get::<_, i64>(0)
            )
            .unwrap(),
            2
        );
    }

    #[test]
    fn rejected_semantic_output_preserves_deterministic_snapshot() {
        let conn = setup();
        let baseline_conn = setup();
        let candidates = collect_candidates(&conn, DAY_START, DAY_END, GENERATED_AT, 5).unwrap();
        let rejected = super::super::semantic_edition::parse(
            r#"{"groups":[{"members":[0,999],"importance":5,"confidence":1,"reason":"invalid handle"}]}"#,
            candidates.len(),
        );
        let result = finish_semantic(
            &conn,
            DAY_START,
            DAY_END,
            GENERATED_AT,
            5,
            &candidate_fingerprint(&candidates),
            rejected,
        )
        .unwrap();
        let baseline =
            get_or_generate(&baseline_conn, DAY_START, DAY_END, GENERATED_AT, 5).unwrap();
        assert_eq!(
            serde_json::to_string(&result).unwrap(),
            serde_json::to_string(&baseline).unwrap()
        );
    }

    #[test]
    fn semantic_importance_overrides_category_quota_without_dropping_omissions() {
        let conn = setup();
        let candidates = collect_candidates(&conn, DAY_START, DAY_END, GENERATED_AT, 5).unwrap();
        let low = candidates
            .iter()
            .position(|candidate| candidate.rank.story_id == "top-d")
            .unwrap();
        let groups = super::super::semantic_edition::parse(
            &format!(
                r#"{{"groups":[{{"members":[{low}],"importance":5,"confidence":1,"reason":"Major impact"}}]}}"#
            ),
            candidates.len(),
        );
        let result = finish_semantic(
            &conn,
            DAY_START,
            DAY_END,
            GENERATED_AT,
            5,
            &candidate_fingerprint(&candidates),
            groups,
        )
        .unwrap();
        assert_eq!(result.items.len(), 5);
        assert_eq!(result.items[0].snapshot.story_id, "top-d");
    }

    fn raw_articles(conn: &Connection) -> Vec<String> {
        queries::get_articles(
            conn,
            &ArticleFilter {
                feed_id: None,
                feed_ids: None,
                search: None,
                theme_id: None,
                is_read: None,
                is_starred: None,
                limit: Some(1_000),
                published_after: None,
                offset: None,
            },
        )
        .expect("raw feed")
        .into_iter()
        .map(|article| article.article.id)
        .collect()
    }

    #[test]
    fn consumed_story_returns_only_after_material_update_not_duplicate() {
        let conn = setup_empty();
        let ingest = |id: &str, title: &str, at: i64| {
            let article = Article {
                id: id.into(),
                feed_id: "feed-1".into(),
                title: title.into(),
                url: Some(format!("https://example.com/{id}")),
                author: None,
                content_html: None,
                content_text: Some("The product starts shipping this month in cities.".into()),
                published_at: Some(at),
                fetched_at: at,
                is_read: false,
                is_starred: false,
                feedly_entry_id: None,
                comments_url: None,
            };
            queries::insert_article(&conn, &article).unwrap();
            story_clustering::process_article(&conn, &article).unwrap()
        };
        let title = "Acme launches solar battery for homes";
        let original = ingest("original", title, DAY_START - 40_000);
        let first =
            get_or_generate(&conn, DAY_START - 86_400, DAY_START, DAY_START - 1, 5).unwrap();
        assert!(first
            .items
            .iter()
            .any(|item| item.snapshot.story_id == original.story_id));
        let duplicate = ingest("copy", title, DAY_START + 100);
        assert_eq!(duplicate.story_id, original.story_id);
        assert_eq!(duplicate.membership_type, StoryMembershipType::Duplicate);
        let unconsumed = get_or_generate(&conn, DAY_START, DAY_END, GENERATED_AT, 5).unwrap();
        assert!(unconsumed
            .items
            .iter()
            .any(|item| item.snapshot.story_id == original.story_id));
        let consumed = set_item_consumed(
            &conn,
            &first.edition.id,
            &original.story_id,
            true,
            GENERATED_AT,
        )
        .unwrap();
        let second = get_or_generate(&conn, DAY_START, DAY_END, GENERATED_AT, 10).unwrap();
        assert!(!second
            .items
            .iter()
            .any(|item| item.snapshot.story_id == original.story_id));
        let preserved = load(&conn, &first.edition.id).unwrap();
        assert_eq!(preserved.items.len(), consumed.items.len());
        let original_item = preserved
            .items
            .iter()
            .find(|item| item.snapshot.story_id == original.story_id)
            .unwrap();
        assert!(original_item.snapshot.is_consumed);
        assert_eq!(original_item.member_article_ids, vec!["original"]);

        let title = "Acme launches solar battery update for homes after recall";
        let update = ingest("update-original", title, DAY_START + 200);
        assert_eq!(update.story_id, original.story_id);
        assert_eq!(update.membership_type, StoryMembershipType::Update);
        ingest("update-copy", title, DAY_START + 201);
        let fresh = get_or_generate(&conn, DAY_START, DAY_END, GENERATED_AT, 20).unwrap();
        assert!(fresh
            .items
            .iter()
            .any(|item| item.snapshot.story_id == original.story_id));
        let frozen = get_or_generate(&conn, DAY_START, DAY_END, GENERATED_AT, 10).unwrap();
        assert!(frozen
            .items
            .iter()
            .any(|item| item.snapshot.story_id == original.story_id));
        set_item_consumed(
            &conn,
            &fresh.edition.id,
            &original.story_id,
            true,
            GENERATED_AT,
        )
        .unwrap();
        ingest("third-day-copy", title, DAY_END + 100);
        let third = get_or_generate(&conn, DAY_END, DAY_END + 86_400, DAY_END + 101, 5).unwrap();
        assert!(!third
            .items
            .iter()
            .any(|item| item.snapshot.story_id == original.story_id));
    }

    #[test]
    fn edition_is_capped_ranked_and_keeps_member_sources() {
        let conn = setup();
        let raw_before = raw_articles(&conn);
        let edition = get_or_generate(&conn, DAY_START, DAY_END, GENERATED_AT, 5).expect("edition");
        assert_eq!(edition.edition.id, "today-1728000-1814400-5");
        assert_eq!(edition.edition.total_source_count, 3);
        assert_eq!(edition.total_count, 5);
        assert_eq!(edition.items.len(), 5);
        assert!(!edition
            .items
            .iter()
            .any(|item| item.snapshot.story_id == "prior-day"));
        let sections: BTreeSet<&str> = edition
            .items
            .iter()
            .map(|item| item.snapshot.section.as_str())
            .collect();
        assert!(sections.contains(SECTION_UPDATES));
        assert!(sections.contains(SECTION_UNIQUE_FINDS));
        assert!(sections.contains(SECTION_WIDELY_COVERED));
        // The page runs in order of importance. Section is metadata on each
        // item; it no longer decides where the item sits.
        let mut ranked = story_clustering::rank_stories(&conn, GENERATED_AT, MAX_RANK_CANDIDATES)
            .expect("ranked");
        ranked.sort_by(|left, right| {
            right
                .score
                .partial_cmp(&left.score)
                .unwrap_or(Ordering::Equal)
                .then_with(|| left.story_id.cmp(&right.story_id))
        });
        let on_page: Vec<&str> = edition
            .items
            .iter()
            .map(|item| item.snapshot.story_id.as_str())
            .collect();
        let by_score: Vec<&str> = ranked
            .iter()
            .map(|rank| rank.story_id.as_str())
            .filter(|id| on_page.contains(id))
            .collect();
        assert_eq!(on_page, by_score);
        for item in &edition.items {
            let reason = item.snapshot.snapshot_reason.as_deref().unwrap_or_default();
            match item.snapshot.section.as_str() {
                SECTION_TOP_STORIES => assert_eq!(reason, "high_rank_recent"),
                SECTION_WIDELY_COVERED => assert!(reason.starts_with("widely_covered:")),
                SECTION_UPDATES => assert_eq!(reason, "updated_story"),
                SECTION_UNIQUE_FINDS => assert_eq!(reason, "unique_singleton"),
                other => panic!("unexpected section {other}"),
            }
        }
        for item in &edition.items {
            assert!(item.representative_article_id.is_some());
            assert!(!item.member_article_ids.is_empty());
            assert_eq!(item.member_article_ids.len(), item.member_articles.len());
        }
        let wide = edition
            .items
            .iter()
            .find(|item| item.snapshot.story_id == "wide")
            .expect("wide story");
        assert_eq!(wide.member_articles.len(), 3);
        assert!(conn
            .execute(
                "UPDATE edition_item_articles
                 SET snapshot_article_title = 'rewritten'
                 WHERE edition_id = ?1 AND story_id = 'wide'",
                params![edition.edition.id],
            )
            .is_err());
        assert_eq!(raw_articles(&conn), raw_before);
    }

    #[test]
    fn identical_inputs_reuse_immutable_snapshot_but_new_limit_gets_new_id() {
        let conn = setup();
        let first = get_or_generate(&conn, DAY_START, DAY_END, GENERATED_AT, 5).expect("first");
        let first_member_ids: Vec<Vec<String>> = first
            .items
            .iter()
            .map(|item| item.member_article_ids.clone())
            .collect();
        conn.execute(
            "UPDATE stories SET title = 'changed after snapshot' WHERE id = 'wide'",
            [],
        )
        .expect("change live story");
        queries::insert_article(
            &conn,
            &Article {
                id: "wide-late-source".into(),
                feed_id: "feed-4".into(),
                title: "Late source".into(),
                url: Some("https://source4.example/wide/late".into()),
                author: None,
                content_html: None,
                content_text: Some("Later coverage".into()),
                published_at: Some(GENERATED_AT),
                fetched_at: GENERATED_AT,
                is_read: false,
                is_starred: false,
                feedly_entry_id: None,
                comments_url: None,
            },
        )
        .expect("late article");
        queries::upsert_story_article(
            &conn,
            &StoryArticle {
                story_id: "wide".into(),
                article_id: "wide-late-source".into(),
                membership_type: StoryMembershipType::Coverage,
                confidence: Some(0.9),
                added_at: GENERATED_AT,
            },
        )
        .expect("late membership");
        let reused =
            get_or_generate(&conn, DAY_START, DAY_END, GENERATED_AT + 1, 5).expect("reuse");
        assert_eq!(first.edition.id, reused.edition.id);
        assert_eq!(
            first
                .items
                .iter()
                .map(|item| (&item.snapshot.story_id, &item.snapshot.snapshot_title))
                .collect::<Vec<_>>(),
            reused
                .items
                .iter()
                .map(|item| (&item.snapshot.story_id, &item.snapshot.snapshot_title))
                .collect::<Vec<_>>()
        );
        assert_eq!(
            reused
                .items
                .iter()
                .map(|item| item.member_article_ids.clone())
                .collect::<Vec<_>>(),
            first_member_ids
        );
        let larger = get_or_generate(&conn, DAY_START, DAY_END, GENERATED_AT, 10).expect("larger");
        assert_ne!(first.edition.id, larger.edition.id);
        assert_eq!(larger.edition.story_limit, 10);
        assert!(larger.items.len() <= 10);
    }

    #[test]
    fn consumption_progress_completes_and_can_reopen_without_snapshot_changes() {
        let conn = setup();
        let edition = get_or_generate(&conn, DAY_START, DAY_END, GENERATED_AT, 5).expect("edition");
        let snapshot_titles: Vec<String> = edition
            .items
            .iter()
            .map(|item| item.snapshot.snapshot_title.clone())
            .collect();
        let mut progress = edition;
        let first_story_id = progress.items[0].snapshot.story_id.clone();
        let first_article_ids = progress.items[0].member_article_ids.clone();
        for story_id in progress
            .items
            .iter()
            .map(|item| item.snapshot.story_id.clone())
            .collect::<Vec<_>>()
        {
            progress =
                set_item_consumed(&conn, &progress.edition.id, &story_id, true, GENERATED_AT)
                    .expect("consume");
            if story_id == first_story_id {
                for article_id in &first_article_ids {
                    assert_eq!(
                        conn.query_row(
                            "SELECT is_read FROM articles WHERE id = ?1",
                            params![article_id],
                            |row| row.get::<_, i32>(0),
                        )
                        .unwrap(),
                        1
                    );
                }
            }
        }
        assert_eq!(progress.consumed_count, progress.total_count);
        assert_eq!(progress.edition.status, EditionStatus::Completed);
        assert_eq!(progress.edition.completed_at, Some(GENERATED_AT));
        let reopened = set_item_consumed(
            &conn,
            &progress.edition.id,
            &progress.items[0].snapshot.story_id,
            false,
            GENERATED_AT + 1,
        )
        .expect("reopen");
        assert_eq!(reopened.edition.status, EditionStatus::Ready);
        assert_eq!(reopened.edition.completed_at, None);
        for article_id in &first_article_ids {
            assert_eq!(
                conn.query_row(
                    "SELECT is_read FROM articles WHERE id = ?1",
                    params![article_id],
                    |row| row.get::<_, i32>(0),
                )
                .unwrap(),
                1
            );
        }
        assert_eq!(
            reopened
                .items
                .iter()
                .map(|item| item.snapshot.snapshot_title.clone())
                .collect::<Vec<_>>(),
            snapshot_titles
        );
    }

    #[test]
    fn empty_edition_recovers_after_feed_refresh_then_freezes() {
        let conn = setup_empty();
        let empty = get_or_generate(&conn, DAY_START, DAY_END, DAY_START + 1, 5).unwrap();
        let still_empty = get_or_generate(&conn, DAY_START, DAY_END, DAY_START + 2, 5).unwrap();
        assert!(still_empty.items.is_empty());
        assert_eq!(still_empty.edition.generated_at, empty.edition.generated_at);
        assert_eq!(still_empty.edition.completed_at, empty.edition.completed_at);
        add_story(&conn, "arrived", 1, false, DAY_START + 3);
        let populated = get_or_generate(&conn, DAY_START, DAY_END, DAY_START + 10, 5).unwrap();
        assert_eq!(populated.edition.id, empty.edition.id);
        assert_eq!(populated.items.len(), 1);
        assert_eq!(populated.edition.status, EditionStatus::Ready);
        assert_eq!(populated.edition.completed_at, None);
        assert_eq!(populated.edition.generated_at, DAY_START + 10);
        add_story(&conn, "later", 3, true, DAY_START + 20);
        let frozen = get_or_generate(&conn, DAY_START, DAY_END, DAY_START + 30, 5).unwrap();
        assert_eq!(frozen.items.len(), 1);
        assert_eq!(frozen.items[0].snapshot.story_id, "arrived");
        assert_eq!(frozen.edition.generated_at, populated.edition.generated_at);
    }

    #[test]
    fn empty_edition_is_explicitly_completed() {
        let conn = Connection::open_in_memory().expect("open");
        conn.execute_batch("PRAGMA foreign_keys=ON;").expect("fk");
        migrations::run_migrations(&conn).expect("migrate");
        let edition = get_or_generate(&conn, DAY_START, DAY_END, GENERATED_AT, 5).expect("empty");
        assert_eq!(edition.total_count, 0);
        assert_eq!(edition.edition.total_source_count, 0);
        assert_eq!(edition.edition.status, EditionStatus::Completed);
        assert_eq!(edition.edition.completed_at, Some(GENERATED_AT));
    }
}
