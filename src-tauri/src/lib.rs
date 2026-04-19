mod commands;
mod db;
mod feed;
mod ai;

use ai::local_provider::{self, SharedModelState, LAST_USED_AT};
use commands::ai::{SharedSummaryCache, SummaryCache, SummaryGeneration};
use commands::models::DownloadCancelFlag;
use db::models::AppSettings;
use db::{queries, Database};
use std::sync::atomic::{AtomicBool, Ordering};
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

            // Read user's preload / idle-evict / power preferences.
            let (preload_mode, idle_evict_minutes, model_path, gpu_layers) = {
                let conn = database.conn.lock().expect("db lock");
                let settings: AppSettings = queries::get_setting(&conn, "app_settings")
                    .ok()
                    .flatten()
                    .and_then(|s| serde_json::from_str(&s).ok())
                    .unwrap_or_default();
                let power_mode = settings
                    .ai
                    .local_power_mode
                    .as_deref()
                    .unwrap_or("balanced")
                    .to_string();
                let (effective_layers, _) = local_provider::resolve_power_profile(
                    &power_mode,
                    settings.ai.local_gpu_layers,
                );
                (
                    settings
                        .ai
                        .local_preload
                        .clone()
                        .unwrap_or_else(|| "off".to_string()),
                    settings.ai.local_idle_evict_minutes.unwrap_or(10),
                    settings.ai.local_model_path.clone(),
                    effective_layers,
                )
            };

            // Optional preload.
            if preload_mode == "on" {
                if let Some(path_str) = model_path {
                    let path = std::path::PathBuf::from(path_str);
                    let state = model_state.clone();
                    tauri::async_runtime::spawn(async move {
                        tokio::task::spawn_blocking(move || {
                            log::info!("Preloading local model: {}", path.display());
                            match local_provider::load_model(&path, gpu_layers) {
                                Ok(loaded) => {
                                    state.blocking_lock().replace(loaded);
                                    local_provider::mark_used();
                                    log::info!("Model preloaded");
                                }
                                Err(e) => log::warn!("Preload failed: {}", e),
                            }
                        })
                        .await
                        .ok();
                    });
                }
            }

            // Idle-eviction watcher. 0 minutes = never evict.
            if idle_evict_minutes > 0 {
                let state = model_state.clone();
                let idle_secs = (idle_evict_minutes as i64) * 60;
                tauri::async_runtime::spawn(async move {
                    let mut ticker = tokio::time::interval(std::time::Duration::from_secs(120));
                    ticker.tick().await;
                    loop {
                        ticker.tick().await;
                        let now = chrono::Utc::now().timestamp();
                        let last = LAST_USED_AT.load(Ordering::Relaxed);
                        if last == 0 {
                            continue;
                        }
                        if now - last >= idle_secs {
                            let mut guard = state.lock().await;
                            if guard.is_some() {
                                log::info!("Evicting idle local model from VRAM");
                                guard.take();
                            }
                        }
                    }
                });
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
            commands::feeds::rename_feed,
            commands::feeds::count_starred_in_feed,
            commands::feeds::refresh_feed,
            commands::feeds::refresh_all_feeds,
            commands::feeds::get_total_unread,
            commands::feeds::import_feedly,
            commands::feeds::feedly_preview,
            commands::feeds::connect_feedly,
            commands::feeds::disconnect_feedly,
            commands::feeds::get_feedly_status,
            commands::feeds::feedly_oauth_login,
            commands::feeds::feedly_oauth_available,
            commands::feeds::feedly_preview_stored,
            commands::feeds::import_feedly_stored,
            commands::feeds::preview_opml,
            commands::feeds::import_opml,
            commands::feeds::list_folders,
            commands::feeds::create_folder,
            commands::feeds::create_smart_folder,
            commands::feeds::rename_folder,
            commands::feeds::update_smart_folder_rules,
            commands::feeds::delete_folder,
            commands::feeds::reorder_folders,
            commands::feeds::assign_feed_to_folder,
            commands::feeds::preview_smart_folder,
            commands::feeds::feeds_in_folder,
            commands::feeds::ai_auto_organize_feeds,
            commands::feeds::ai_match_feeds_for_topic,
            commands::feeds::apply_folder_organization,
            commands::feeds::list_duplicate_feeds,
            commands::feeds::merge_duplicate_feeds,
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
            commands::ai::get_article_theme_tags,
            commands::ai::triage_articles,
            commands::ai::get_inbox_articles,
            commands::ai::get_triage_stats,
            commands::ai::record_reading_time,
            commands::ai::set_article_feedback,
            commands::ai::set_priority_override,
            commands::ai::get_preference_profile,
            commands::ai::get_article_interaction,
            // Chat
            commands::chat::chat_with_article,
            commands::chat::chat_with_articles,
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
                // Drop the loaded model before the runtime tears down
                let state = app.state::<SharedModelState>();
                if let Ok(mut guard) = state.try_lock() {
                    guard.take();
                };
                // Force-exit to skip C++ static destructors (llama.cpp Metal
                // cleanup asserts on shutdown and crashes the process).
                std::process::exit(0);
            }
        });
}
