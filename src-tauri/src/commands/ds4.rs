use crate::ai::ds4_provider::{runtime, validate_model_path, Ds4Status};

#[tauri::command]
pub async fn ds4_status() -> Result<Ds4Status, String> {
    Ok(runtime().status().await)
}

#[tauri::command]
pub async fn ds4_start(model_path: String) -> Result<Ds4Status, String> {
    let path = std::path::PathBuf::from(model_path);
    validate_model_path(&path)?;
    let manager = runtime();
    manager.start(&path).await?;
    Ok(manager.status().await)
}

#[tauri::command]
pub async fn ds4_stop() -> Result<Ds4Status, String> {
    Ok(runtime().stop().await)
}
