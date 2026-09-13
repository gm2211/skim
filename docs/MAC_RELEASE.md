# Mac release verification

The current on-device helper build targets Apple Silicon and macOS 14+. Apple
Foundation Models additionally requires macOS 26 and Apple Intelligence enabled.

`./release.sh` builds the Swift helper, its Metal library, the frontend and the
Tauri app. Set `APPLE_SIGNING_IDENTITY` and pass `--sign` for development or
distribution signing. Local builds use an ad-hoc signature.

For a direct `tauri build --no-sign`, run `sh scripts/sign-macos.sh` afterward.
The signing script creates relative resource aliases and signs the helper with
sandbox inheritance before signing the parent. Do not sign the whole tree with
`--deep`: the parent and helper require different entitlements.

Release checks:

- Run frontend tests and the Rust library suite. The existing local-model
  integration test requires a separately downloaded GGUF file.
- Verify `codesign --verify --deep --strict Skim.app` and the bundle version.
- With `mlx-community/gemma-3-1b-it-4bit` already downloaded in the app's model
  cache, run `Skim.app/Contents/MacOS/skim --check-on-device-ai` with a 120-second
  process timeout. This uses fixed arithmetic prompts, reports Foundation Models
  availability and checks two MLX completions through the signed parent/helper.
  It does not open the UI, read the library or change settings.
- Check the installed app's binary hash matches the verified build, then inspect
  title-bar controls and provider setup navigation in the running app.

Resource data belongs in `Contents/Resources`. Relative aliases in
`Contents/MacOS` satisfy MLX and SwiftPM lookup without placing unsigned data in
a code directory. The model weights are downloaded separately, never bundled.
