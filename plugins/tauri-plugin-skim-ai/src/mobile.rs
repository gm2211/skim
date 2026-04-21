use serde::de::DeserializeOwned;
use tauri::{
    plugin::{PluginApi, PluginHandle},
    AppHandle, Runtime,
};

use crate::models::*;

#[cfg(target_os = "ios")]
tauri::ios_plugin_binding!(init_plugin_skim_ai);

pub fn init<R: Runtime, C: DeserializeOwned>(
    _app: &AppHandle<R>,
    api: PluginApi<R, C>,
) -> crate::Result<SkimAi<R>> {
    #[cfg(target_os = "android")]
    let handle = api.register_android_plugin("app.skim.skim_ai", "SkimAIPlugin")?;
    #[cfg(target_os = "ios")]
    let handle = api.register_ios_plugin(init_plugin_skim_ai)?;
    Ok(SkimAi(handle))
}

pub struct SkimAi<R: Runtime>(PluginHandle<R>);

impl<R: Runtime> SkimAi<R> {
    pub fn mlx_is_available(&self) -> crate::Result<bool> {
        self.0.run_mobile_plugin::<bool>("mlxIsAvailable", ()).map_err(Into::into)
    }

    pub fn mlx_is_model_downloaded(&self, payload: RepoIdArgs) -> crate::Result<bool> {
        self.0.run_mobile_plugin::<bool>("mlxIsModelDownloaded", payload).map_err(Into::into)
    }

    pub fn mlx_download_model(&self, payload: RepoIdArgs) -> crate::Result<()> {
        self.0.run_mobile_plugin::<()>("mlxDownloadModel", payload).map_err(Into::into)
    }

    pub fn mlx_delete_model(&self, payload: RepoIdArgs) -> crate::Result<()> {
        self.0.run_mobile_plugin::<()>("mlxDeleteModel", payload).map_err(Into::into)
    }

    pub fn mlx_complete(&self, payload: CompleteArgs) -> crate::Result<String> {
        self.0.run_mobile_plugin::<String>("mlxComplete", payload).map_err(Into::into)
    }

    pub fn fm_is_available(&self) -> crate::Result<bool> {
        self.0.run_mobile_plugin::<bool>("fmIsAvailable", ()).map_err(Into::into)
    }

    pub fn fm_complete(&self, payload: CompleteArgs) -> crate::Result<String> {
        self.0.run_mobile_plugin::<String>("fmComplete", payload).map_err(Into::into)
    }

    pub fn ios_keychain_store(&self, payload: KeychainSetArgs) -> crate::Result<()> {
        self.0.run_mobile_plugin::<()>("iosKeychainStore", payload).map_err(Into::into)
    }

    pub fn ios_keychain_load(&self, payload: KeychainKeyArgs) -> crate::Result<Option<String>> {
        self.0.run_mobile_plugin::<Option<String>>("iosKeychainLoad", payload).map_err(Into::into)
    }

    pub fn ios_keychain_clear(&self, payload: KeychainKeyArgs) -> crate::Result<()> {
        self.0.run_mobile_plugin::<()>("iosKeychainClear", payload).map_err(Into::into)
    }
}
