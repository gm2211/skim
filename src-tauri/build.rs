fn main() {
    let policy = "../shared/SkimStoryPolicy/Sources/SkimStoryPolicy";
    println!("cargo:rerun-if-changed={policy}/SkimStoryPolicy.c");
    println!("cargo:rerun-if-changed={policy}/SkimUnicodeCaseFold.h");
    println!("cargo:rerun-if-changed={policy}/include/SkimStoryPolicy.h");
    cc::Build::new()
        .file(format!("{policy}/SkimStoryPolicy.c"))
        .include(format!("{policy}/include"))
        .compile("skim_story_policy");
    tauri_build::build()
}
