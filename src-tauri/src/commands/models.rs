use crate::ai::model_manager;
use crate::db::Database;
use crate::db::queries;
use serde::Serialize;
use std::path::PathBuf;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use sysinfo::System;
use tauri::State;

pub struct DownloadCancelFlag(pub Arc<AtomicBool>);

#[tauri::command]
pub async fn search_hf_models(query: String) -> Result<Vec<model_manager::HfModelInfo>, String> {
    model_manager::search_hf_models(&query).await
}

#[tauri::command]
pub async fn get_hf_model_files(
    repo_id: String,
) -> Result<Vec<model_manager::HfModelFile>, String> {
    model_manager::get_hf_model_files(&repo_id).await
}

fn resolve_models_dir(db: &Database) -> Result<PathBuf, String> {
    let conn = db.conn.lock().map_err(|e| e.to_string())?;
    let settings_json = queries::get_setting(&conn, "app_settings").map_err(|e| e.to_string())?;
    let settings: crate::db::models::AppSettings = settings_json
        .as_deref()
        .map(|s| serde_json::from_str(s).unwrap_or_default())
        .unwrap_or_default();

    if let Some(ref dir) = settings.ai.models_directory {
        Ok(PathBuf::from(dir))
    } else {
        Ok(db.data_dir.join("models"))
    }
}

#[tauri::command]
pub async fn download_model(
    app_handle: tauri::AppHandle,
    db: State<'_, Database>,
    cancel_flag: State<'_, DownloadCancelFlag>,
    repo_id: String,
    filename: String,
) -> Result<String, String> {
    let models_dir = resolve_models_dir(&db)?;
    let cancel = cancel_flag.0.clone();
    let path =
        model_manager::download_model(&app_handle, &repo_id, &filename, &models_dir, cancel)
            .await?;
    Ok(path.to_string_lossy().to_string())
}

#[tauri::command]
pub async fn cancel_download(cancel_flag: State<'_, DownloadCancelFlag>) -> Result<(), String> {
    cancel_flag
        .0
        .store(true, std::sync::atomic::Ordering::SeqCst);
    Ok(())
}

#[tauri::command]
pub async fn list_local_models(
    db: State<'_, Database>,
) -> Result<Vec<model_manager::LocalModel>, String> {
    let models_dir = resolve_models_dir(&db)?;
    model_manager::list_local_models(&models_dir)
}

#[tauri::command]
pub async fn delete_local_model(
    path: String,
) -> Result<(), String> {
    model_manager::delete_local_model(&PathBuf::from(path))
}

#[derive(Serialize)]
pub struct SystemInfo {
    pub total_memory_gb: f64,
    pub available_memory_gb: f64,
    pub max_model_size_gb: f64, // recommended max GGUF size
}

#[tauri::command]
pub async fn get_system_info() -> Result<SystemInfo, String> {
    let mut sys = System::new_all();
    sys.refresh_memory();

    let total_gb = sys.total_memory() as f64 / (1024.0 * 1024.0 * 1024.0);
    let available_gb = sys.available_memory() as f64 / (1024.0 * 1024.0 * 1024.0);

    // On macOS with unified memory, models can use ~75% of total RAM
    // Leave headroom for the OS and app itself
    let max_model_gb = (total_gb * 0.70).floor();

    Ok(SystemInfo {
        total_memory_gb: (total_gb * 10.0).round() / 10.0,
        available_memory_gb: (available_gb * 10.0).round() / 10.0,
        max_model_size_gb: max_model_gb,
    })
}
