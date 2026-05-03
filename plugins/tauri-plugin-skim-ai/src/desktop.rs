//! Desktop stub — on-device MLX + Apple Foundation Models + iOS Keychain are
//! iOS-only. Every desktop method reports a clear "unavailable" error so
//! callers can gracefully fall back to cloud providers.

use serde::de::DeserializeOwned;
use tauri::{plugin::PluginApi, AppHandle, Runtime};

use crate::models::*;

const UNAVAILABLE: &str = "skim-ai: on-device tier is only available on iOS";

pub fn init<R: Runtime, C: DeserializeOwned>(
    app: &AppHandle<R>,
    _api: PluginApi<R, C>,
) -> crate::Result<SkimAi<R>> {
    Ok(SkimAi(app.clone()))
}

pub struct SkimAi<R: Runtime>(AppHandle<R>);

impl<R: Runtime> SkimAi<R> {
    pub fn mlx_is_available(&self) -> crate::Result<bool> { Ok(false) }

    pub fn mlx_is_model_downloaded(&self, _payload: RepoIdArgs) -> crate::Result<bool> { Ok(false) }

    pub fn mlx_download_model(&self, _payload: RepoIdArgs) -> crate::Result<()> {
        Err(crate::Error::Other(UNAVAILABLE.into()))
    }

    pub fn mlx_delete_model(&self, _payload: RepoIdArgs) -> crate::Result<()> {
        Err(crate::Error::Other(UNAVAILABLE.into()))
    }

    pub fn mlx_complete(&self, _payload: CompleteArgs) -> crate::Result<String> {
        Err(crate::Error::Other(UNAVAILABLE.into()))
    }

    pub fn fm_is_available(&self) -> crate::Result<bool> { Ok(false) }

    pub fn fm_availability(&self) -> crate::Result<FoundationModelAvailability> {
        Ok(FoundationModelAvailability {
            available: false,
            status: "unsupported-platform".into(),
            message: "Apple Foundation Models are only wired into the iOS app bundle.".into(),
        })
    }

    pub fn fm_complete(&self, _payload: CompleteArgs) -> crate::Result<String> {
        Err(crate::Error::Other(UNAVAILABLE.into()))
    }

    pub fn ios_keychain_store(&self, _payload: KeychainSetArgs) -> crate::Result<()> {
        Err(crate::Error::Other(UNAVAILABLE.into()))
    }

    pub fn ios_keychain_load(&self, _payload: KeychainKeyArgs) -> crate::Result<Option<String>> {
        Ok(None)
    }

    pub fn ios_keychain_clear(&self, _payload: KeychainKeyArgs) -> crate::Result<()> {
        Err(crate::Error::Other(UNAVAILABLE.into()))
    }
}
