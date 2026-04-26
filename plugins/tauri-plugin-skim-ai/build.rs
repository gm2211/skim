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

    // MLX's CPU backend pulls in LAPACK SVD symbols (sgesdd/dgesdd) provided
    // by Apple's Accelerate framework. Link it for the iOS plugin target.
    let target = std::env::var("TARGET").unwrap_or_default();
    if target.contains("apple-ios") || target.contains("apple-darwin") {
        println!("cargo:rustc-link-lib=framework=Accelerate");
        println!("cargo:rustc-link-lib=framework=Metal");
        println!("cargo:rustc-link-lib=framework=MetalKit");
        println!("cargo:rustc-link-lib=framework=Foundation");
    }
}
