mod commands;
mod db;
mod feed;
mod ai;

use ai::local_provider::{self, SharedModelState};
use commands::ai::{SharedSummaryCache, SummaryCache, SummaryGeneration};
use commands::models::DownloadCancelFlag;
use db::models::AppSettings;
use db::{queries, Database};
use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use tauri::{Manager, RunEvent};
use tokio::sync::Mutex;

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
            let model_state = Arc::new(Mutex::new(None::<ai::local_provider::LoadedModel>)) as SharedModelState;

            // Preload local model in background if configured
            {
                let conn = database.conn.lock().expect("db lock");
                let settings: AppSettings = queries::get_setting(&conn, "app_settings")
                    .ok()
                    .flatten()
                    .and_then(|s| serde_json::from_str(&s).ok())
                    .unwrap_or_default();

                if settings.ai.provider == "local" {
                    if let Some(ref model_path) = settings.ai.local_model_path {
                        let path = std::path::PathBuf::from(model_path);
                        let gpu_layers = settings.ai.local_gpu_layers.unwrap_or(-1);
                        let state = model_state.clone();
                        std::thread::spawn(move || {
                            log::info!("Preloading local model: {}", path.display());
                            match local_provider::load_model(&path, gpu_layers) {
                                Ok(loaded) => {
                                    state.blocking_lock().replace(loaded);
                                    log::info!("Model preloaded successfully");
                                }
                                Err(e) => log::warn!("Failed to preload model: {}", e),
                            }
                        });
                    }
                }
            }

            app.manage(database);
            app.manage(model_state);
            app.manage(DownloadCancelFlag(Arc::new(AtomicBool::new(false))));
            app.manage(Arc::new(Mutex::new(SummaryCache::new())) as SharedSummaryCache);
            app.manage(SummaryGeneration(std::sync::atomic::AtomicU64::new(0)));
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
            commands::ai::cancel_summarize,
            commands::ai::generate_themes,
            commands::ai::get_themes,
            commands::ai::triage_articles,
            commands::ai::get_inbox_articles,
            commands::ai::get_triage_stats,
            // Chat
            commands::chat::chat_with_article,
            commands::chat::web_search,
            // Settings
            commands::settings::get_settings,
            commands::settings::update_settings,
            // Models
            commands::models::search_hf_models,
            commands::models::get_hf_model_files,
            commands::models::download_model,
            commands::models::cancel_download,
            commands::models::list_local_models,
            commands::models::delete_local_model,
            commands::models::get_system_info,
        ])
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app, event| {
            if let RunEvent::Exit = event {
                // Drop the loaded model cleanly before the runtime tears down
                let state = app.state::<SharedModelState>();
                if let Ok(mut guard) = state.try_lock() {
                    guard.take();
                };
            }
        });
}
