use crate::db::models::{ArticleFilter, ArticleWithFeed};
use crate::db::queries;
use crate::db::Database;
use tauri::State;

#[tauri::command]
pub async fn get_articles(
    db: State<'_, Database>,
    filter: ArticleFilter,
) -> Result<Vec<ArticleWithFeed>, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::get_articles(&conn, &filter).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn get_article(
    db: State<'_, Database>,
    article_id: String,
) -> Result<ArticleWithFeed, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::get_article_by_id(&conn, &article_id)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "Article not found".to_string())
}

#[tauri::command]
pub async fn mark_articles_read(
    db: State<'_, Database>,
    article_ids: Vec<String>,
) -> Result<(), String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::mark_articles_read(&conn, &article_ids).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn mark_all_read(
    db: State<'_, Database>,
    feed_id: Option<String>,
) -> Result<(), String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::mark_all_read(&conn, feed_id.as_deref()).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn toggle_star(
    db: State<'_, Database>,
    article_id: String,
) -> Result<bool, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    queries::toggle_star(&conn, &article_id).map_err(|e| e.to_string())
}
