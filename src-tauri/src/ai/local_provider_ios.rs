//! iOS stub for `local_provider`. llama.cpp doesn't cross-compile to iOS and
//! the "Local (Embedded)" provider tier is unsupported on mobile — on-device
//! inference on iOS goes through the MLX Swift Tauri plugin instead.
//!
//! This stub exists so command signatures that reference `SharedModelState`
//! still compile on iOS without pulling in llama.cpp types.

#![allow(dead_code)]

use std::sync::Arc;
use std::sync::atomic::AtomicI64;
use tokio::sync::Mutex;

pub type LoadedModel = ();
pub type SharedModelState = Arc<Mutex<Option<LoadedModel>>>;

pub static LAST_USED_AT: AtomicI64 = AtomicI64::new(0);

pub fn mark_used() {}

pub fn resolve_power_profile(_power_mode: &str, _user_layers: Option<i32>) -> (i32, i32) {
    (0, 0)
}

pub fn load_model(_path: &std::path::Path, _gpu_layers: i32) -> Result<LoadedModel, String> {
    Err("Local llama.cpp provider is not supported on iOS — use the MLX tier instead".to_string())
}
