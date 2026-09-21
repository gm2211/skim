#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    #[cfg(feature = "devbridge")]
    if std::env::args().any(|arg| arg == "--dev-bridge") {
        skim_lib::devbridge::run();
        return;
    }
    #[cfg(target_os = "macos")]
    if std::env::args().any(|arg| arg == "--check-on-device-ai") {
        // Exercise the bundled helper under this app's real sandbox identity,
        // without opening the UI, changing settings, or reading the library.
        if let Err(error) = mac_ai_check::run() {
            eprintln!("On-device AI check failed: {error}");
            std::process::exit(1);
        }
        return;
    }
    #[cfg(target_os = "macos")]
    if let Some(index) = std::env::args().position(|arg| arg == "--check-ds4-model") {
        let model_path = std::env::args().nth(index + 1).unwrap_or_default();
        if model_path.is_empty() {
            eprintln!("DS4 check failed: --check-ds4-model requires a GGUF path");
            std::process::exit(2);
        }
        if let Err(error) = skim_lib::run_ds4_check(model_path) {
            eprintln!("DS4 check failed: {error}");
            std::process::exit(1);
        }
        return;
    }
    #[cfg(not(feature = "devbridge"))]
    skim_lib::run();
}

#[cfg(target_os = "macos")]
mod mac_ai_check;
