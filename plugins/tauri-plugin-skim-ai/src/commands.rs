use tauri::{command, AppHandle, Runtime};

use crate::models::*;
use crate::Result;
use crate::SkimAiExt;

#[command]
pub(crate) async fn mlx_is_available<R: Runtime>(app: AppHandle<R>) -> Result<bool> {
    app.skim_ai().mlx_is_available()
}

#[command]
pub(crate) async fn mlx_is_model_downloaded<R: Runtime>(
    app: AppHandle<R>,
    payload: RepoIdArgs,
) -> Result<bool> {
    app.skim_ai().mlx_is_model_downloaded(payload)
}

#[command]
pub(crate) async fn mlx_download_model<R: Runtime>(
    app: AppHandle<R>,
    payload: RepoIdArgs,
) -> Result<()> {
    app.skim_ai().mlx_download_model(payload)
}

#[command]
pub(crate) async fn mlx_delete_model<R: Runtime>(
    app: AppHandle<R>,
    payload: RepoIdArgs,
) -> Result<()> {
    app.skim_ai().mlx_delete_model(payload)
}

#[command]
pub(crate) async fn mlx_complete<R: Runtime>(
    app: AppHandle<R>,
    payload: CompleteArgs,
) -> Result<String> {
    app.skim_ai().mlx_complete(payload)
}

#[command]
pub(crate) async fn fm_is_available<R: Runtime>(app: AppHandle<R>) -> Result<bool> {
    app.skim_ai().fm_is_available()
}

#[command]
pub(crate) async fn fm_complete<R: Runtime>(
    app: AppHandle<R>,
    payload: CompleteArgs,
) -> Result<String> {
    app.skim_ai().fm_complete(payload)
}

#[command]
pub(crate) async fn ios_keychain_store<R: Runtime>(
    app: AppHandle<R>,
    payload: KeychainSetArgs,
) -> Result<()> {
    app.skim_ai().ios_keychain_store(payload)
}

#[command]
pub(crate) async fn ios_keychain_load<R: Runtime>(
    app: AppHandle<R>,
    payload: KeychainKeyArgs,
) -> Result<Option<String>> {
    app.skim_ai().ios_keychain_load(payload)
}

#[command]
pub(crate) async fn ios_keychain_clear<R: Runtime>(
    app: AppHandle<R>,
    payload: KeychainKeyArgs,
) -> Result<()> {
    app.skim_ai().ios_keychain_clear(payload)
}
