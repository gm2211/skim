mod commands;
mod db;
mod feed;
mod ai;

use db::Database;
use tauri::Manager;
use std::sync::Mutex;

struct WebviewState {
    active_label: Mutex<Option<String>>,
}

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
            app.manage(WebviewState {
                active_label: Mutex::new(None),
            });
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
            commands::articles::mark_all_read,
            commands::articles::toggle_star,
            commands::articles::fetch_full_article,
            // Webview
            open_article_webview,
            close_article_webview,
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

#[tauri::command]
async fn open_article_webview(
    app: tauri::AppHandle,
    wv_state: tauri::State<'_, WebviewState>,
    url: String,
    title: String,
) -> Result<(), String> {
    // Close existing webview window if any
    {
        let mut label = wv_state.active_label.lock().map_err(|e| e.to_string())?;
        if let Some(old_label) = label.take() {
            if let Some(win) = app.get_webview_window(&old_label) {
                let _ = win.close();
            }
        }
    }

    let label = format!("article-{}", uuid::Uuid::new_v4().to_string().split('-').next().unwrap_or("0"));
    let parsed_url: url::Url = url.parse().map_err(|e: url::ParseError| e.to_string())?;

    // Get main window position and size for relative placement
    let main_window = app.get_webview_window("main").ok_or("Main window not found")?;
    let main_pos = main_window.outer_position().map_err(|e| e.to_string())?;
    let main_size = main_window.outer_size().map_err(|e| e.to_string())?;

    let win = tauri::webview::WebviewWindowBuilder::new(
        &app,
        &label,
        tauri::WebviewUrl::External(parsed_url),
    )
    .title(&title)
    .inner_size(
        (main_size.width as f64 * 0.7).max(800.0),
        (main_size.height as f64 * 0.9).max(600.0),
    )
    .position(
        main_pos.x as f64 + 80.0,
        main_pos.y as f64 + 40.0,
    )
    .incognito(true)
    .build()
    .map_err(|e| format!("Failed to create webview window: {}", e))?;

    win.set_focus().map_err(|e| e.to_string())?;

    let mut active = wv_state.active_label.lock().map_err(|e| e.to_string())?;
    *active = Some(label);

    Ok(())
}

#[tauri::command]
async fn close_article_webview(
    app: tauri::AppHandle,
    wv_state: tauri::State<'_, WebviewState>,
) -> Result<(), String> {
    let mut label = wv_state.active_label.lock().map_err(|e| e.to_string())?;
    if let Some(old_label) = label.take() {
        if let Some(win) = app.get_webview_window(&old_label) {
            win.close().map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}
