use tauri::{
  plugin::{Builder, TauriPlugin},
  Manager, Runtime,
};

pub use models::*;

#[cfg(desktop)]
mod desktop;
#[cfg(mobile)]
mod mobile;

mod commands;
mod error;
mod models;

pub use error::{Error, Result};

#[cfg(desktop)]
use desktop::SkimAi;
#[cfg(mobile)]
use mobile::SkimAi;

/// Extensions to [`tauri::App`], [`tauri::AppHandle`] and [`tauri::Window`] to access the skim-ai APIs.
pub trait SkimAiExt<R: Runtime> {
  fn skim_ai(&self) -> &SkimAi<R>;
}

impl<R: Runtime, T: Manager<R>> crate::SkimAiExt<R> for T {
  fn skim_ai(&self) -> &SkimAi<R> {
    self.state::<SkimAi<R>>().inner()
  }
}

/// Initializes the plugin.
pub fn init<R: Runtime>() -> TauriPlugin<R> {
  Builder::new("skim-ai")
    .invoke_handler(tauri::generate_handler![
      commands::mlx_is_available,
      commands::mlx_is_model_downloaded,
      commands::mlx_download_model,
      commands::mlx_delete_model,
      commands::mlx_complete,
      commands::fm_is_available,
      commands::fm_complete,
      commands::ios_keychain_store,
      commands::ios_keychain_load,
      commands::ios_keychain_clear,
    ])
    .setup(|app, api| {
      #[cfg(mobile)]
      let skim_ai = mobile::init(app, api)?;
      #[cfg(desktop)]
      let skim_ai = desktop::init(app, api)?;
      app.manage(skim_ai);
      Ok(())
    })
    .build()
}
