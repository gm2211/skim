pub mod provider;
pub mod native_provider;
pub mod ds4_provider;
pub mod prompts;
pub mod publication;
pub mod model_manager;
pub mod claude_oauth;

#[cfg(not(target_os = "ios"))]
pub mod local_provider;

#[cfg(target_os = "ios")]
#[path = "local_provider_ios.rs"]
pub mod local_provider;
