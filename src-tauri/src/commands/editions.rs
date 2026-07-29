use crate::db::today_edition::{self, TodayEditionItemView, TodayEditionView};
use crate::db::Database;
use tauri::State;

#[tauri::command]
pub async fn get_or_generate_today_edition(
    db: State<'_, Database>,
    starts_at: i64,
    ends_at: i64,
    generated_at: i64,
    story_limit: i64,
) -> Result<TodayEditionView, String> {
    let conn = db.conn.lock().map_err(|error| error.to_string())?;
    today_edition::get_or_generate(&conn, starts_at, ends_at, generated_at, story_limit)
        .map_err(|error| error.to_string())
}

#[tauri::command]
pub async fn list_today_edition_items(
    db: State<'_, Database>,
    edition_id: String,
) -> Result<Vec<TodayEditionItemView>, String> {
    let conn = db.conn.lock().map_err(|error| error.to_string())?;
    today_edition::list_items(&conn, &edition_id).map_err(|error| error.to_string())
}

#[tauri::command]
pub async fn set_today_edition_item_consumed(
    db: State<'_, Database>,
    edition_id: String,
    story_id: String,
    is_consumed: bool,
    changed_at: i64,
) -> Result<TodayEditionView, String> {
    let conn = db.conn.lock().map_err(|error| error.to_string())?;
    today_edition::set_item_consumed(&conn, &edition_id, &story_id, is_consumed, changed_at)
        .map_err(|error| error.to_string())
}
