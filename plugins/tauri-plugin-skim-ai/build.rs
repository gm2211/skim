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
    // tauri-utils + swift-rs default to iOS 13 / macOS 10.13 when these env
    // vars are unset. swift-jinja and MLXLMCommon use iOS 16+ / macOS 14+
    // APIs, so the swift-package compile fails unless the deployment target
    // is bumped. Force the floor here so the build is correct regardless of
    // how cargo was invoked (xcode preBuildScript, plain cargo build, etc.)
    if std::env::var_os("IPHONEOS_DEPLOYMENT_TARGET").is_none() {
        std::env::set_var("IPHONEOS_DEPLOYMENT_TARGET", "17.0");
    }
    if std::env::var_os("MACOSX_DEPLOYMENT_TARGET").is_none() {
        std::env::set_var("MACOSX_DEPLOYMENT_TARGET", "14.0");
    }
    println!("cargo:rerun-if-env-changed=IPHONEOS_DEPLOYMENT_TARGET");
    println!("cargo:rerun-if-env-changed=MACOSX_DEPLOYMENT_TARGET");

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
