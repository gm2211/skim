const COMMANDS: &[&str] = &[
    "mlx_is_available",
    "mlx_is_model_downloaded",
    "mlx_download_model",
    "mlx_delete_model",
    "mlx_complete",
    "fm_is_available",
    "fm_complete",
    "ios_keychain_store",
    "ios_keychain_load",
    "ios_keychain_clear",
];

fn main() {
    tauri_plugin::Builder::new(COMMANDS)
        .ios_path("ios")
        .build();
}
