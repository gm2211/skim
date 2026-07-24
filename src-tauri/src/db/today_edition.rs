//! Persisted finite Today editions.
//!
//! Edition snapshots are generated from the additive story index. Raw article
//! rows and the chronological feed queries remain untouched.

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
const MAX_RANK_CANDIDATES: usize = 10_000;

#[derive(Debug, Clone, Serialize)]
pub struct TodayEditionMemberArticle {
    pub article_id: String,
    pub feed_id: String,
    pub feed_title: String,
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

#[derive(Debug)]
struct Candidate {
    rank: story_clustering::RankedStory,
    revision: StoryRevision,
    is_update: bool,
}

#[derive(Debug)]
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

pub fn get_or_generate(
    conn: &Connection,
    starts_at: i64,
    ends_at: i64,
    generated_at: i64,
    story_limit: i64,
) -> Result<TodayEditionView, rusqlite::Error> {
    validate_window_and_limit(starts_at, ends_at, generated_at, story_limit)?;
    let id = edition_id(starts_at, ends_at, story_limit);
    if queries::get_edition(conn, &id)?.is_none() {
        generate(conn, &id, starts_at, ends_at, generated_at, story_limit)?;
    }
    load(conn, &id)
}

fn validate_window_and_limit(
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

fn generate(
    conn: &Connection,
    id: &str,
    starts_at: i64,
    ends_at: i64,
    generated_at: i64,
    story_limit: i64,
) -> Result<(), rusqlite::Error> {
    let mut ranked = story_clustering::rank_stories(conn, generated_at, MAX_RANK_CANDIDATES)?;
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
        let memberships = queries::list_story_articles(conn, &rank.story_id)?;
        let is_update = memberships
            .iter()
            .any(|membership| membership.membership_type == StoryMembershipType::Update);
        candidates.push(Candidate {
            rank,
            revision,
            is_update,
        });
    }

    let mut selected = select_candidates(&candidates, story_limit as usize);
    selected.sort_by(|left, right| {
        section_order(section_for(left))
            .cmp(&section_order(section_for(right)))
            .then_with(|| {
                right
                    .rank
                    .score
                    .partial_cmp(&left.rank.score)
                    .unwrap_or(Ordering::Equal)
            })
            .then_with(|| left.rank.story_id.cmp(&right.rank.story_id))
    });
    let selected_with_members = selected
        .iter()
        .map(|candidate| {
            Ok((
                *candidate,
                member_snapshots(
                    conn,
                    &candidate.rank.story_id,
                    candidate.revision.representative_article_id.as_deref(),
                )?,
            ))
        })
        .collect::<Result<Vec<_>, rusqlite::Error>>()?;
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
    let transaction = conn.unchecked_transaction()?;
    queries::insert_edition(&transaction, &edition)?;
    for (position, (candidate, _)) in selected_with_members.iter().enumerate() {
        let section = section_for(candidate);
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
                candidate.revision.source_count.max(1),
                reason_for(section, candidate.revision.source_count),
                candidate.rank.is_unique_find as i32,
            ],
        )?;
    }
    for (candidate, members) in &selected_with_members {
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
    transaction.commit()
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

fn section_order(section: &str) -> u8 {
    match section {
        SECTION_TOP_STORIES => 0,
        SECTION_WIDELY_COVERED => 1,
        SECTION_UPDATES => 2,
        SECTION_UNIQUE_FINDS => 3,
        _ => 4,
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
            Ok(TodayEditionItemView {
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
            Ok(TodayEditionMemberArticle {
                article_id: row.get(0)?,
                feed_id: row.get(1)?,
                feed_title: row.get(2)?,
                feed_icon_url: row.get(3)?,
                title: row.get(4)?,
                url: row.get(5)?,
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

    fn raw_articles(conn: &Connection) -> Vec<String> {
        queries::get_articles(
            conn,
            &ArticleFilter {
                feed_id: None,
                theme_id: None,
                is_read: None,
                is_starred: None,
                limit: Some(1_000),
                offset: None,
            },
        )
        .expect("raw feed")
        .into_iter()
        .map(|article| article.article.id)
        .collect()
    }

    #[test]
    fn edition_is_capped_sectioned_and_keeps_member_sources() {
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
        let section_positions: Vec<u8> = edition
            .items
            .iter()
            .map(|item| section_order(&item.snapshot.section))
            .collect();
        assert!(section_positions.windows(2).all(|pair| pair[0] <= pair[1]));
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
