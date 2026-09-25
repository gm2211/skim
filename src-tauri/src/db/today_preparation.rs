//! Resumable derived inference. Frozen editions never serve as mutable workspaces.
use super::{
    models::AppSettings,
    queries,
    semantic_edition::SemanticGroup,
    today_edition::{self, Candidate, TodayEditionView},
};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::ffi::CStr;

type Result<T> = std::result::Result<T, String>;
extern "C" {
    fn skim_preparation_version() -> u32;
    fn skim_preparation_assessment_output_tokens() -> usize;
    fn skim_preparation_proposal_output_tokens() -> usize;
    fn skim_preparation_assessment_prompt() -> *const std::os::raw::c_char;
    fn skim_preparation_assessment_verdict(response: *const u8, length: usize) -> i32;
    fn skim_preparation_proposal_prompt() -> *const std::os::raw::c_char;
    fn skim_preparation_proposal_labels(
        response: *const u8,
        length: usize,
        count: usize,
        labels: *mut i32,
        labels_count: usize,
    ) -> i32;
    fn skim_preparation_window_count(count: usize) -> u64;
    fn skim_preparation_window_at(
        count: usize,
        ordinal: u64,
        a: *mut usize,
        an: *mut usize,
        b: *mut usize,
        bn: *mut usize,
    ) -> i32;
    fn skim_preparation_partition(
        count: usize,
        left: *const usize,
        right: *const usize,
        edges: usize,
        labels: *mut i32,
        labels_count: usize,
    ) -> i32;
    fn skim_preparation_group_importance(
        ratings: *const i32,
        labels: *const i32,
        count: usize,
        group: i32,
    ) -> i32;
}
fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}
fn hash(text: &str) -> String {
    format!("{:x}", Sha256::digest(text.as_bytes()))
}
#[derive(Debug, Clone, Copy)]
pub struct Window {
    pub starts: i64,
    pub ends: i64,
    pub generated: i64,
    pub limit: i64,
}
impl Window {
    pub fn key(self) -> String {
        today_edition::edition_id(self.starts, self.ends, self.limit)
    }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodayPreparationStatus {
    pub scope_key: String,
    pub eligible_count: usize,
    pub assessed_count: usize,
    pub assessment_failed_count: usize,
    pub proposal_window_count: usize,
    pub proposal_completed_count: usize,
    pub proposal_failed_count: usize,
    pub proposed_pair_count: usize,
    pub verified_pair_count: usize,
    pub verification_failed_count: usize,
    pub state: String,
    pub manifest: String,
    pub can_publish: bool,
    pub active_edition_id: Option<String>,
}
#[derive(Clone)]
pub struct Task {
    pub key: String,
    pub kind: &'static str,
    pub payload: String,
    pub prompt: String,
    pub tokens: i64,
    pub members: Vec<usize>,
}
#[derive(Clone)]
struct Outcome {
    result: Option<Value>,
    error: Option<String>,
}
pub struct Snapshot {
    pub status: TodayPreparationStatus,
    pub tasks: Vec<Task>,
    pub pending: Vec<Task>,
    pub settings: AppSettings,
    pub model: String,
    pub inference: String,
    pub candidates: Vec<Candidate>,
    ratings: Vec<i32>,
    edges: Vec<(usize, usize)>,
}
pub fn prompt(kind: &str) -> String {
    unsafe {
        match kind {
            "assessment" => CStr::from_ptr(skim_preparation_assessment_prompt())
                .to_string_lossy()
                .into_owned(),
            "proposal" => CStr::from_ptr(skim_preparation_proposal_prompt())
                .to_string_lossy()
                .into_owned(),
            _ => super::story_policy::semantic_pair_prompt().into(),
        }
    }
}
pub fn validate(task: &Task, response: &str) -> Result<Value> {
    match task.kind {
        "assessment" => {
            let value =
                unsafe { skim_preparation_assessment_verdict(response.as_ptr(), response.len()) };
            if (0..=5).contains(&value) {
                Ok(json!(value))
            } else {
                Err("Invalid report assessment".into())
            }
        }
        "proposal" => {
            let mut labels = vec![-1; task.members.len()];
            let count = unsafe {
                skim_preparation_proposal_labels(
                    response.as_ptr(),
                    response.len(),
                    labels.len(),
                    labels.as_mut_ptr(),
                    labels.len(),
                )
            };
            if count > 0 {
                Ok(json!(labels))
            } else {
                Err("Incomplete related-report assessment".into())
            }
        }
        _ => {
            let value = super::story_policy::semantic_pair_verdict(response);
            if (0..=2).contains(&value) {
                Ok(json!(value))
            } else {
                Err("Invalid report comparison".into())
            }
        }
    }
}
fn valid_cached(task: &Task, value: &Value) -> bool {
    match task.kind {
        "assessment" => value.as_i64().is_some_and(|v| (0..=5).contains(&v)),
        "pair" => value.as_i64().is_some_and(|v| (0..=2).contains(&v)),
        _ => value.as_array().is_some_and(|labels| {
            labels.len() == task.members.len()
                && labels
                    .iter()
                    .all(|v| v.as_u64().is_some_and(|n| n < labels.len() as u64))
        }),
    }
}
fn task(kind: &'static str, payload: Value, members: Vec<usize>, identity: &str) -> Task {
    let payload = payload.to_string();
    let prompt = prompt(kind);
    let tokens = match kind {
        "assessment" => (unsafe { skim_preparation_assessment_output_tokens() }) as i64,
        "proposal" => (unsafe { skim_preparation_proposal_output_tokens() }) as i64,
        _ => super::story_policy::semantic_pair_output_tokens() as i64,
    };
    let key = hash(&json!([identity, kind, prompt, payload, tokens]).to_string());
    Task {
        key,
        kind,
        payload,
        prompt,
        tokens,
        members,
    }
}
fn current_settings(conn: &Connection) -> Result<AppSettings> {
    Ok(queries::get_setting(conn, "app_settings")
        .map_err(err)?
        .as_deref()
        .and_then(|s| serde_json::from_str(s).ok())
        .unwrap_or_default())
}
pub fn active(conn: &Connection, window: Window) -> Result<Option<TodayEditionView>> {
    let id: Option<String> = conn
        .query_row(
            "SELECT active_edition_id FROM today_preparation_scopes WHERE scope_key=?1",
            [window.key()],
            |r| r.get(0),
        )
        .optional()
        .map_err(err)?
        .flatten();
    if let Some(id) = id {
        return today_edition::frozen(conn, &id).map_err(err);
    }
    Ok(None)
}
pub fn snapshot(conn: &Connection, w: Window, retry: bool) -> Result<Snapshot> {
    today_edition::validate_window_and_limit(w.starts, w.ends, w.generated, w.limit)
        .map_err(err)?;
    let settings = current_settings(conn)?;
    let model = (if settings.ai.provider == "mlx" {
        settings
            .ai
            .local_model_path
            .as_ref()
            .filter(|v| !v.trim().is_empty())
    } else {
        None
    })
    .or_else(|| settings.ai.model.as_ref().filter(|v| !v.trim().is_empty()))
    .cloned()
    .unwrap_or_else(|| crate::commands::ai::default_model(&settings.ai.provider));
    let inference=hash(&json!({"provider":settings.ai.provider,"model":model,"endpoint":settings.ai.endpoint,"local_model_path":settings.ai.local_model_path,"models_directory":settings.ai.models_directory,"version":unsafe{skim_preparation_version()},"temperature":0}).to_string());
    let scope = w.key();
    conn.execute("INSERT INTO today_preparation_scopes(scope_key,inference_key,updated_at) VALUES(?1,?2,?3) ON CONFLICT(scope_key) DO UPDATE SET inference_key=excluded.inference_key,updated_at=excluded.updated_at",params![scope,inference,w.generated]).map_err(err)?;
    let mut candidates =
        today_edition::collect_candidates(conn, w.starts, w.ends, w.generated, w.limit)
            .map_err(err)?;
    let mut eligible = Vec::new();
    for candidate in candidates {
        if !consumed(
            conn,
            &candidate.rank.story_id,
            candidate.revision.revision_number,
            w,
        )? {
            eligible.push(candidate)
        }
    }
    candidates = eligible;
    candidates.sort_by(|a, b| a.rank.story_id.cmp(&b.rank.story_id));
    let mut slots: BTreeMap<String, usize> = conn
        .prepare("SELECT story_id,slot FROM today_preparation_slots WHERE scope_key=?1")
        .map_err(err)?
        .query_map([&scope], |r| Ok((r.get(0)?, r.get::<_, i64>(1)? as usize)))
        .map_err(err)?
        .collect::<std::result::Result<_, _>>()
        .map_err(err)?;
    let mut next = slots.values().max().map_or(0, |v| v + 1);
    for c in &candidates {
        if !slots.contains_key(&c.rank.story_id) {
            conn.execute(
                "INSERT INTO today_preparation_slots VALUES(?1,?2,?3)",
                params![scope, c.rank.story_id, next as i64],
            )
            .map_err(err)?;
            slots.insert(c.rank.story_id.clone(), next);
            next += 1;
        }
    }
    let by_slot: BTreeMap<usize, usize> = candidates
        .iter()
        .enumerate()
        .map(|(i, c)| (slots[&c.rank.story_id], i))
        .collect();
    let reports:Vec<Value>=candidates.iter().map(|c|json!({"title":c.revision.title.chars().take(240).collect::<String>(),"excerpt":c.evidence,"activity_date":chrono::DateTime::from_timestamp(c.timestamp,0).map(|d|d.format("%Y-%m-%d").to_string()).unwrap_or_default()})).collect();
    conn.execute(
        "DELETE FROM today_preparation_tasks WHERE updated_at<?1",
        [w.generated.saturating_sub(7 * 86400)],
    )
    .map_err(err)?;
    let outcomes: BTreeMap<String, Outcome> = conn
        .prepare("SELECT task_key,result,error FROM today_preparation_tasks")
        .map_err(err)?
        .query_map([], |r| {
            let raw: Option<String> = r.get(1)?;
            Ok((
                r.get(0)?,
                Outcome {
                    result: raw.and_then(|v| serde_json::from_str(&v).ok()),
                    error: r.get(2)?,
                },
            ))
        })
        .map_err(err)?
        .collect::<std::result::Result<_, _>>()
        .map_err(err)?;
    let mut tasks: Vec<Task> = reports
        .iter()
        .enumerate()
        .map(|(i, r)| task("assessment", r.clone(), vec![i], &inference))
        .collect();
    let mut ratings = vec![-1; candidates.len()];
    for t in &tasks {
        if let Some(v) = outcomes
            .get(&t.key)
            .and_then(|o| o.result.as_ref())
            .and_then(|v| v.as_i64())
        {
            ratings[t.members[0]] = v as i32;
        }
    }
    let windows = unsafe { skim_preparation_window_count(next) };
    if windows == u64::MAX {
        return Err("Too many preparation windows".into());
    }
    let mut pairs = BTreeSet::new();
    for ordinal in 0..windows {
        let (mut a, mut an, mut b, mut bn) = (0, 0, 0, 0);
        if unsafe { skim_preparation_window_at(next, ordinal, &mut a, &mut an, &mut b, &mut bn) }
            == 0
        {
            return Err("Invalid preparation window".into());
        }
        let members: Vec<usize> = (a..a + an)
            .chain(b..b + bn)
            .filter_map(|slot| by_slot.get(&slot).copied())
            .collect();
        if members.is_empty() {
            continue;
        }
        let input: Vec<Value> = members
            .iter()
            .enumerate()
            .map(|(local, i)| {
                let mut r = reports[*i].clone();
                r["index"] = local.into();
                r
            })
            .collect();
        let t = task("proposal", json!({"reports":input}), members, &inference);
        if let Some(labels) = outcomes
            .get(&t.key)
            .and_then(|o| o.result.as_ref())
            .and_then(|v| v.as_array())
        {
            if valid_cached(&t, &json!(labels)) {
                for i in 0..labels.len() {
                    for j in i + 1..labels.len() {
                        if labels[i] == labels[j] {
                            let x = t.members[i];
                            let y = t.members[j];
                            pairs.insert((x.min(y), x.max(y)));
                        }
                    }
                }
            }
        }
        tasks.push(t);
    }
    let mut edges = Vec::new();
    for (a, b) in pairs {
        let t = task(
            "pair",
            json!({"report_a":reports[a],"report_b":reports[b]}),
            vec![a, b],
            &inference,
        );
        if outcomes
            .get(&t.key)
            .and_then(|o| o.result.as_ref())
            .and_then(|v| v.as_i64())
            == Some(1)
        {
            edges.push((a, b))
        }
        tasks.push(t);
    }
    if retry {
        for t in &tasks {
            conn.execute(
                "DELETE FROM today_preparation_tasks WHERE task_key=?1 AND error IS NOT NULL",
                [&t.key],
            )
            .map_err(err)?;
        }
        return snapshot(conn, w, false);
    }
    let mut status = TodayPreparationStatus {
        scope_key: scope.clone(),
        eligible_count: candidates.len(),
        assessed_count: 0,
        assessment_failed_count: 0,
        proposal_window_count: 0,
        proposal_completed_count: 0,
        proposal_failed_count: 0,
        proposed_pair_count: 0,
        verified_pair_count: 0,
        verification_failed_count: 0,
        state: "preparing".into(),
        manifest: String::new(),
        can_publish: false,
        active_edition_id: None,
    };
    let mut pending = Vec::new();
    let mut manifest_tasks = Vec::new();
    for t in &tasks {
        let outcome = outcomes.get(&t.key);
        let done = outcome.is_some_and(|o| o.result.as_ref().is_some_and(|v| valid_cached(t, v)));
        let failed = outcome.is_some_and(|o| o.error.is_some());
        match t.kind {
            "assessment" => {
                status.assessed_count += usize::from(done);
                status.assessment_failed_count += usize::from(failed)
            }
            "proposal" => {
                status.proposal_window_count += 1;
                status.proposal_completed_count += usize::from(done);
                status.proposal_failed_count += usize::from(failed)
            }
            _ => {
                status.proposed_pair_count += 1;
                status.verified_pair_count += usize::from(done);
                status.verification_failed_count += usize::from(failed)
            }
        }
        if !done && !failed {
            pending.push(t.clone())
        }
        manifest_tasks.push(json!([t.key, outcome.and_then(|o| o.result.clone())]));
    }
    let failed = status.assessment_failed_count
        + status.proposal_failed_count
        + status.verification_failed_count;
    status.state = if settings.ai.provider == "none" {
        "disabled"
    } else if candidates.is_empty() {
        "empty"
    } else if pending.is_empty() {
        if failed > 0 {
            "failed"
        } else {
            "ready"
        }
    } else {
        "preparing"
    }
    .into();
    // Publication identity excludes recency/personalization but includes source binding.
    status.manifest = hash(
        &json!([
            inference,
            candidates
                .iter()
                .map(|c| json!([c.rank.story_id, c.revision, c.sources]))
                .collect::<Vec<_>>(),
            manifest_tasks
        ])
        .to_string(),
    );
    let (active,manifest):(Option<String>,Option<String>)=conn.query_row("SELECT active_edition_id,active_manifest FROM today_preparation_scopes WHERE scope_key=?1",[&scope],|r|Ok((r.get(0)?,r.get(1)?))).map_err(err)?;
    status.active_edition_id = active.or_else(|| {
        queries::get_edition(conn, &scope)
            .ok()
            .flatten()
            .map(|_| scope.clone())
    });
    status.can_publish = status.state == "ready" && manifest.as_deref() != Some(&status.manifest);
    Ok(Snapshot {
        status,
        tasks,
        pending,
        settings,
        model,
        inference,
        candidates,
        ratings,
        edges,
    })
}
fn consumed(conn: &Connection, story: &str, revision: i64, w: Window) -> Result<bool> {
    conn.query_row("SELECT EXISTS(SELECT 1 FROM edition_items i JOIN editions e ON e.id=i.edition_id JOIN edition_item_story_revisions m ON m.edition_id=i.edition_id AND m.item_story_id=i.story_id WHERE m.member_story_id=?1 AND i.is_consumed=1 AND e.starts_at<=?2 AND NOT EXISTS(SELECT 1 FROM story_revisions r WHERE r.story_id=?1 AND r.revision_number>m.revision_number AND r.revision_number<=?3 AND r.is_material_change=1))",params![story,w.starts,revision],|r|r.get(0)).map_err(err)
}
pub fn commit(
    conn: &Connection,
    w: Window,
    inference: &str,
    task: &Task,
    response: Result<Value>,
) -> Result<bool> {
    let current = snapshot(conn, w, false)?;
    if current.inference != inference || !current.tasks.iter().any(|t| t.key == task.key) {
        return Ok(false);
    }
    let (result, error) = match response {
        Ok(value) => (Some(value.to_string()), None),
        Err(e) => (None, Some(e)),
    };
    conn.execute("INSERT INTO today_preparation_tasks(task_key,kind,payload,result,error,updated_at) VALUES(?1,?2,?3,?4,?5,?6) ON CONFLICT(task_key) DO UPDATE SET result=excluded.result,error=excluded.error,updated_at=excluded.updated_at",params![task.key,task.kind,task.payload,result,error,w.generated]).map_err(err)?;
    Ok(true)
}
pub fn publish(conn: &Connection, w: Window, manifest: &str) -> Result<TodayEditionView> {
    let transaction = conn.unchecked_transaction().map_err(err)?;
    let snapshot = snapshot(&transaction, w, false)?;
    let id = format!("{}-prepared-{}", w.key(), manifest);
    if snapshot.status.manifest != manifest || snapshot.status.state != "ready" {
        return Err(
            "Preparation changed or is incomplete. Refresh preparation before opening.".into(),
        );
    }
    if let Some(view) = today_edition::frozen(&transaction, &id).map_err(err)? {
        transaction.execute("UPDATE today_preparation_scopes SET active_edition_id=?2,active_manifest=?3 WHERE scope_key=?1",params![w.key(),id,manifest]).map_err(err)?;
        transaction.commit().map_err(err)?;
        return Ok(view);
    }
    let count = snapshot.candidates.len();
    let mut labels = vec![-1; count];
    let left: Vec<_> = snapshot.edges.iter().map(|p| p.0).collect();
    let right: Vec<_> = snapshot.edges.iter().map(|p| p.1).collect();
    let groups = unsafe {
        skim_preparation_partition(
            count,
            left.as_ptr(),
            right.as_ptr(),
            left.len(),
            labels.as_mut_ptr(),
            labels.len(),
        )
    };
    if groups <= 0 {
        return Err("Invalid prepared groups".into());
    }
    let mut semantic = Vec::new();
    for group in 0..groups {
        let importance = unsafe {
            skim_preparation_group_importance(
                snapshot.ratings.as_ptr(),
                labels.as_ptr(),
                count,
                group,
            )
        };
        if importance < 0 {
            return Err("Invalid prepared importance".into());
        }
        semantic.push(SemanticGroup {
            members: labels
                .iter()
                .enumerate()
                .filter_map(|(i, l)| (*l == group).then_some(i))
                .collect(),
            importance: importance as f64,
            confidence: 1.0,
            reason: "From your feeds".into(),
        });
    }
    today_edition::persist_candidates(
        &transaction,
        &id,
        w.starts,
        w.ends,
        w.generated,
        w.limit,
        snapshot.candidates,
        Some(semantic),
    )
    .map_err(err)?;
    transaction
        .execute(
            "INSERT INTO today_edition_preparation VALUES(?1,?2,?3,?4)",
            params![
                id,
                w.key(),
                manifest,
                serde_json::to_string(&snapshot.status).map_err(err)?
            ],
        )
        .map_err(err)?;
    transaction.execute("UPDATE today_preparation_scopes SET active_edition_id=?2,active_manifest=?3 WHERE scope_key=?1",params![w.key(),id,manifest]).map_err(err)?;
    transaction.commit().map_err(err)?;
    today_edition::load(conn, &id).map_err(err)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn window() -> Window {
        Window {
            starts: 1_700_006_400,
            ends: 1_700_092_800,
            generated: 1_700_010_000,
            limit: 20,
        }
    }
    fn setup() -> Connection {
        let c = Connection::open_in_memory().unwrap();
        init(&c);
        c
    }
    fn init(c: &Connection) {
        c.execute_batch("PRAGMA foreign_keys=ON").unwrap();
        super::super::migrations::run_migrations(c).unwrap();
        let mut settings = AppSettings::default();
        settings.ai.provider = "openai".into();
        queries::set_setting(
            c,
            "app_settings",
            &serde_json::to_string(&settings).unwrap(),
        )
        .unwrap();
        c.execute("INSERT OR IGNORE INTO feeds(id,title,url,created_at,updated_at) VALUES('f','Source','https://example.test/rss',1,1)",[]).unwrap();
    }
    fn add(c: &Connection, n: usize) {
        let id = format!("s{n:04}");
        let at = window().generated - 50;
        c.execute("INSERT INTO articles(id,feed_id,title,url,content_text,published_at,fetched_at) VALUES(?1,'f',?1,?1,?2,?3,?3)",params![id,format!("Original report evidence {n}."),at]).unwrap();
        c.execute(
            "INSERT INTO stories VALUES(?1,?1,'Brief card',?1,?2,?2,?2,?2)",
            params![id, at],
        )
        .unwrap();
        c.execute(
            "INSERT INTO story_articles VALUES(?1,?1,'coverage',1,?2)",
            params![id, at],
        )
        .unwrap();
        c.execute("INSERT INTO story_revisions(story_id,revision_number,title,summary,representative_article_id,created_at) VALUES(?1,1,?1,'Brief card',?1,?2)",params![id,at]).unwrap();
    }
    fn complete(c: &Connection, w: Window) {
        loop {
            let s = snapshot(c, w, false).unwrap();
            let Some(t) = s.pending.first() else {
                assert_eq!(s.status.state, "ready");
                break;
            };
            let raw = match t.kind {
                "assessment" => "{\"importance\":4}".into(),
                "proposal" => {
                    json!({"groups":(0..t.members.len()).map(|i|vec![i]).collect::<Vec<_>>()})
                        .to_string()
                }
                _ => "{\"relation\":\"different_event\"}".into(),
            };
            assert!(commit(c, w, &s.inference, t, validate(t, &raw)).unwrap());
        }
    }
    #[test]
    fn full_pool_slots_and_checkpoints_survive_recency_and_append() {
        let c = setup();
        for n in 0..108 {
            add(&c, n)
        }
        let w = window();
        let s = snapshot(&c, w, false).unwrap();
        assert_eq!(s.status.eligible_count, 108);
        assert_eq!(s.status.proposal_window_count, 10);
        assert_eq!(
            s.pending.iter().filter(|t| t.kind == "assessment").count(),
            108
        );
        let t = &s.pending[0];
        assert!(commit(&c, w, &s.inference, t, validate(t, "{\"importance\":5}")).unwrap());
        let later = snapshot(
            &c,
            Window {
                generated: w.generated + 3600,
                ..w
            },
            false,
        )
        .unwrap();
        assert_eq!(later.status.assessed_count, 1);
        assert_eq!(later.tasks[0].key, t.key);
        add(&c, 108);
        let appended = snapshot(&c, w, false).unwrap();
        assert_eq!(appended.status.assessed_count, 1);
        assert_eq!(appended.status.eligible_count, 109);
        assert!(appended.tasks.iter().any(|x| x.key == t.key));
    }
    #[test]
    fn source_config_changes_reject_stale_and_retry_is_explicit() {
        let c = setup();
        add(&c, 0);
        add(&c, 1);
        let w = window();
        let old = snapshot(&c, w, false).unwrap();
        let t = &old.tasks[0];
        c.execute(
            "UPDATE articles SET content_text='New original evidence' WHERE id='s0000'",
            [],
        )
        .unwrap();
        assert!(!commit(&c, w, &old.inference, t, Ok(json!(5))).unwrap());
        let s = snapshot(&c, w, false).unwrap();
        let t = &s.tasks[0];
        assert!(commit(&c, w, &s.inference, t, Err("Malformed response".into())).unwrap());
        let failed = snapshot(&c, w, false).unwrap();
        assert_eq!(failed.status.assessment_failed_count, 1);
        assert!(!failed.pending.iter().any(|x| x.key == t.key));
        let retried = snapshot(&c, w, true).unwrap();
        assert_eq!(retried.status.assessment_failed_count, 0);
        assert!(retried.pending.iter().any(|x| x.key == t.key));
        let mut settings = retried.settings.clone();
        settings.ai.model = Some("different-model".into());
        queries::set_setting(
            &c,
            "app_settings",
            &serde_json::to_string(&settings).unwrap(),
        )
        .unwrap();
        assert!(!commit(&c, w, &retried.inference, t, Ok(json!(5))).unwrap());
    }
    #[test]
    fn persisted_successor_keeps_old_snapshot_and_consumption() {
        let path =
            std::env::temp_dir().join(format!("skim-preparation-{}.db", uuid::Uuid::new_v4()));
        let c = Connection::open(&path).unwrap();
        init(&c);
        for n in 0..3 {
            add(&c, n)
        }
        let w = window();
        complete(&c, w);
        let s = snapshot(&c, w, false).unwrap();
        let first = publish(&c, w, &s.status.manifest).unwrap();
        let before = serde_json::to_value(&first).unwrap();
        assert!(!snapshot(&c, w, false).unwrap().status.can_publish);
        drop(c);
        let c = Connection::open(path).unwrap();
        super::super::migrations::run_migrations(&c).unwrap();
        assert_eq!(snapshot(&c, w, false).unwrap().status.assessed_count, 3);
        assert_eq!(
            serde_json::to_value(active(&c, w).unwrap().unwrap()).unwrap(),
            before
        );
        queries::set_edition_item_consumed(
            &c,
            &first.edition.id,
            &first.items[0].snapshot.story_id,
            true,
            Some(w.generated),
        )
        .unwrap();
        let old =
            serde_json::to_value(today_edition::load(&c, &first.edition.id).unwrap()).unwrap();
        add(&c, 3);
        complete(&c, w);
        let next = snapshot(&c, w, false).unwrap();
        assert_eq!(next.status.eligible_count, 3);
        let second = publish(&c, w, &next.status.manifest).unwrap();
        assert_ne!(first.edition.id, second.edition.id);
        assert_eq!(
            serde_json::to_value(today_edition::load(&c, &first.edition.id).unwrap()).unwrap(),
            old
        );
        assert!(!second
            .items
            .iter()
            .any(|i| i.snapshot.story_id == first.items[0].snapshot.story_id));
    }
    #[test]
    fn cross_block_proposal_requires_pair_verdict_before_publication() {
        let c = setup();
        for n in 0..65 {
            add(&c, n)
        }
        let w = window();
        loop {
            let s = snapshot(&c, w, false).unwrap();
            let Some(t) = s.pending.iter().find(|t| t.kind != "pair") else {
                break;
            };
            let response = if t.kind == "assessment" {
                "{\"importance\":4}".into()
            } else {
                let mut groups: Vec<Vec<usize>> = (0..t.members.len()).map(|i| vec![i]).collect();
                if let (Some(a), Some(b)) = (
                    t.members.iter().position(|v| *v == 0),
                    t.members.iter().position(|v| *v == 64),
                ) {
                    groups.retain(|g| g[0] != a && g[0] != b);
                    groups.push(vec![a, b]);
                }
                json!({"groups":groups}).to_string()
            };
            assert!(commit(&c, w, &s.inference, t, validate(t, &response)).unwrap());
        }
        let s = snapshot(&c, w, false).unwrap();
        assert_eq!(s.status.proposed_pair_count, 1);
        assert!(!s.status.can_publish);
        assert!(publish(&c, w, &s.status.manifest).is_err());
        let t = &s.pending[0];
        assert_eq!(t.kind, "pair");
        assert!(t.payload.contains("Original report evidence 64."));
        assert!(commit(
            &c,
            w,
            &s.inference,
            t,
            validate(t, "{\"relation\":\"same_event\"}")
        )
        .unwrap());
        let ready = snapshot(&c, w, false).unwrap();
        assert!(ready.status.can_publish);
        let view = publish(&c, w, &ready.status.manifest).unwrap();
        assert!(view
            .items
            .iter()
            .any(|i| i.member_article_ids.contains(&"s0000".into())
                && i.member_article_ids.contains(&"s0064".into())));
        let mapped: i64 = c
            .query_row(
                "SELECT count(*) FROM edition_item_story_revisions WHERE edition_id=?1",
                [&view.edition.id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(mapped, view.items.len() as i64 + 1);
    }
    #[test]
    fn stale_successor_cannot_bypass_current_manifest_and_valid_retry_restores_pointer() {
        let c = setup();
        add(&c, 0);
        let w = window();
        complete(&c, w);
        let manifest = snapshot(&c, w, false).unwrap().status.manifest;
        let first = publish(&c, w, &manifest).unwrap();
        assert_eq!(
            publish(&c, w, &manifest).unwrap().edition.id,
            first.edition.id
        );
        c.execute(
            "UPDATE today_preparation_scopes SET active_edition_id=NULL,active_manifest=NULL",
            [],
        )
        .unwrap();
        assert_eq!(
            publish(&c, w, &manifest).unwrap().edition.id,
            first.edition.id
        );
        assert_eq!(active(&c, w).unwrap().unwrap().edition.id, first.edition.id);
        c.execute(
            "UPDATE articles SET content_text='Corrected source evidence' WHERE id='s0000'",
            [],
        )
        .unwrap();
        assert!(publish(&c, w, &manifest).is_err());
        assert_eq!(active(&c, w).unwrap().unwrap().edition.id, first.edition.id);
        complete(&c, w);
        let fresh = snapshot(&c, w, false).unwrap().status.manifest;
        let second = publish(&c, w, &fresh).unwrap();
        assert_ne!(second.edition.id, first.edition.id);
        assert!(publish(&c, w, &manifest).is_err());
        let mut settings = current_settings(&c).unwrap();
        settings.ai.model = Some("changed".into());
        queries::set_setting(
            &c,
            "app_settings",
            &serde_json::to_string(&settings).unwrap(),
        )
        .unwrap();
        assert!(publish(&c, w, &fresh).is_err());
    }
    #[test]
    fn shared_preparation_fixture() {
        let f: Value = serde_json::from_str(include_str!(
            "../../../shared/fixtures/today-preparation-policy.json"
        ))
        .unwrap();
        unsafe {
            assert_eq!(
                skim_preparation_version() as u64,
                f["version"].as_u64().unwrap()
            );
            assert_eq!(
                skim_preparation_assessment_output_tokens() as u64,
                f["assessment_output_tokens"].as_u64().unwrap()
            );
            assert_eq!(
                skim_preparation_proposal_output_tokens() as u64,
                f["proposal_output_tokens"].as_u64().unwrap()
            );
        }
        for x in f["assessments"].as_array().unwrap() {
            let r = x["response"].as_str().unwrap();
            assert_eq!(
                unsafe { skim_preparation_assessment_verdict(r.as_ptr(), r.len()) } as i64,
                x["expected"].as_i64().unwrap(),
                "{x}"
            );
        }
        for x in f["proposals"].as_array().unwrap() {
            let r = x["response"].as_str().unwrap();
            let n = x["count"].as_u64().unwrap() as usize;
            let mut labels = vec![-1; n];
            let result = unsafe {
                skim_preparation_proposal_labels(r.as_ptr(), r.len(), n, labels.as_mut_ptr(), n)
            };
            if x["labels"].is_array() {
                assert!(result > 0, "{x}");
                assert_eq!(json!(labels), x["labels"])
            } else {
                assert_eq!(result, 0, "{x}");
            }
        }
        for x in f["windows"].as_array().unwrap() {
            let n = x["slots"].as_u64().unwrap() as usize;
            assert_eq!(
                unsafe { skim_preparation_window_count(n) },
                x["count"].as_u64().unwrap()
            );
            for pos in x["positions"].as_array().unwrap() {
                let (mut a, mut an, mut b, mut bn) = (0, 0, 0, 0);
                assert_eq!(
                    unsafe {
                        skim_preparation_window_at(
                            n,
                            pos["ordinal"].as_u64().unwrap(),
                            &mut a,
                            &mut an,
                            &mut b,
                            &mut bn,
                        )
                    },
                    1
                );
                assert_eq!(json!([a, an, b, bn]), pos["window"]);
            }
        }
        for x in f["partitions"].as_array().unwrap() {
            let n = x["count"].as_u64().unwrap() as usize;
            let e = x["edges"].as_array().unwrap();
            let a: Vec<usize> = e.iter().map(|p| p[0].as_u64().unwrap() as usize).collect();
            let b: Vec<usize> = e.iter().map(|p| p[1].as_u64().unwrap() as usize).collect();
            let mut labels = vec![-1; n];
            let result = unsafe {
                skim_preparation_partition(
                    n,
                    a.as_ptr(),
                    b.as_ptr(),
                    a.len(),
                    labels.as_mut_ptr(),
                    n,
                )
            };
            if x["invalid"] == true {
                assert_eq!(result, 0)
            } else {
                assert!(result > 0);
                assert_eq!(json!(labels), x["labels"]);
            }
        }
        for x in f["importance"].as_array().unwrap() {
            let ratings: Vec<i32> = serde_json::from_value(x["ratings"].clone()).unwrap();
            let labels: Vec<i32> = serde_json::from_value(x["labels"].clone()).unwrap();
            assert_eq!(
                unsafe {
                    skim_preparation_group_importance(
                        ratings.as_ptr(),
                        labels.as_ptr(),
                        ratings.len(),
                        x["group"].as_i64().unwrap() as i32,
                    )
                } as i64,
                x["expected"].as_i64().unwrap()
            );
        }
    }
}
