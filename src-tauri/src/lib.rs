mod commands;
mod db;
mod feed;
mod ai;

use db::Database;
use tauri::Manager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let _ = env_logger::try_init();

    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            let app_dir = app
                .path()
                .app_data_dir()
                .expect("Failed to get app data directory");
            let database =
                Database::new(app_dir).expect("Failed to initialize database");
            app.manage(database);
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            // Feeds
            commands::feeds::add_feed,
            commands::feeds::list_feeds,
            commands::feeds::remove_feed,
            commands::feeds::refresh_feed,
            commands::feeds::refresh_all_feeds,
            commands::feeds::get_total_unread,
            // Articles
            commands::articles::get_articles,
            commands::articles::get_article,
            commands::articles::mark_articles_read,
            commands::articles::mark_articles_unread,
            commands::articles::mark_all_read,
            commands::articles::toggle_star,
            commands::articles::toggle_read,
            commands::articles::fetch_full_article,
            // AI
            commands::ai::summarize_article,
            commands::ai::generate_themes,
            commands::ai::get_themes,
            // Settings
            commands::settings::get_settings,
            commands::settings::update_settings,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
