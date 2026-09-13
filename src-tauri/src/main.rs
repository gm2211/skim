#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
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
    skim_lib::run()
}

#[cfg(target_os = "macos")]
mod mac_ai_check;
