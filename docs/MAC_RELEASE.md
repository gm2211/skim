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

- Run `python3 plugins/tauri-plugin-skim-ai/tests/test_build_macos_bridge.py` and
  `swift test --package-path shared/SkimInferencePolicy` to cover packaging and
  shared model policy. The bridge build must use the exact `swift build
  --show-bin-path` product; stale products can coexist in its scratch directory.
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

## DeepSeek V4 Flash (DS4)

Mac builds also compile the pinned MIT-licensed DS4 Metal server with
`scripts/build-ds4-macos.sh`. Its source revision is recorded in the bundle at
`Contents/Resources/ds4/REVISION`; Metal sources and license notices ship beside
it. The server inherits Skim's sandbox and listens only on a random loopback port.

Settings → AI → DeepSeek (DS4) offers the dedicated Flash Q2 model for Macs with
96 GiB or more unified memory. The download is 86,720,111,488 bytes (80.8 GiB),
resumable, pinned to a Hugging Face revision and SHA-256 checked before use.
The app starts the runtime when needed; Start/Stop controls are also available.
Provider and model selection remain drafts until Settings is saved. Existing
llama.cpp models remain under Local (Embedded); DS4 files use their own runtime.

For release verification with the model downloaded, run:

```sh
Skim.app/Contents/MacOS/skim --check-ds4-model /path/to/DeepSeek-V4-Flash.gguf
```

Allow up to four minutes for initial Metal startup. This uses synthetic prompts
through the signed parent and bundled server, then stops the server without
opening the UI or reading the article library. Compare the installed parent and
DS4 server hashes with the verified bundle after installation.
