pub mod migrations;
pub mod models;
pub mod queries;
pub mod inbox_rank;
pub mod story_text;
pub mod story_clustering;
pub(crate) mod story_policy;
pub mod today_edition;
pub mod semantic_edition;

use rusqlite::Connection;
use std::convert::Infallible;
use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard, PoisonError};

/// The app's one SQLite connection.
///
/// A panic while a command holds the lock poisons a plain `Mutex`, and from
/// then on every command that touches the library fails until the app is
/// relaunched: opening an article stops marking it read, refreshes stop
/// saving, and the UI keeps showing its last good data. SQLite rolls back
/// any open transaction when the guard unwinds, so the connection is still
/// consistent and it is safe to keep using it.
pub struct DbConn(Mutex<Connection>);

impl DbConn {
    pub fn new(conn: Connection) -> Self {
        DbConn(Mutex::new(conn))
    }

    /// Never fails; the `Result` keeps `lock()?`-style callers unchanged.
    pub fn lock(&self) -> Result<MutexGuard<'_, Connection>, Infallible> {
        Ok(self.0.lock().unwrap_or_else(|poisoned: PoisonError<_>| {
            log::error!("database lock was poisoned by a panic; recovering");
            self.0.clear_poison();
            poisoned.into_inner()
        }))
    }
}

pub struct Database {
    pub conn: DbConn,
    pub data_dir: PathBuf,
}

impl Database {
    pub fn new(app_dir: PathBuf) -> Result<Self, rusqlite::Error> {
        std::fs::create_dir_all(&app_dir).ok();
        let db_path = app_dir.join("skim.db");
        let conn = Connection::open(db_path)?;
        conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")?;
        migrations::run_migrations(&conn)?;
        Ok(Database {
            conn: DbConn::new(conn),
            data_dir: app_dir,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_panic_holding_the_lock_does_not_stop_later_writes() {
        let dir = std::env::temp_dir().join(format!("skim-poison-{}", uuid::Uuid::new_v4()));
        let db = std::sync::Arc::new(Database::new(dir).unwrap());
        db.conn.lock().unwrap().execute_batch(
            "INSERT INTO feeds (id, title, url, created_at, updated_at) VALUES ('f', 'Feed', 'https://f.test', 0, 0);
             INSERT INTO articles (id, feed_id, title, fetched_at) VALUES ('a', 'f', 'Title', 0);",
        ).unwrap();

        let held = db.clone();
        let panicked = std::thread::spawn(move || {
            let _conn = held.conn.lock().unwrap();
            panic!("a command panicked mid-query");
        })
        .join();
        assert!(panicked.is_err());

        let conn = db.conn.lock().unwrap();
        queries::mark_articles_read(&conn, &["a".to_string()]).unwrap();
        let is_read: bool = conn.query_row("SELECT is_read FROM articles WHERE id = 'a'", [], |row| row.get(0)).unwrap();
        assert!(is_read);
    }
}
