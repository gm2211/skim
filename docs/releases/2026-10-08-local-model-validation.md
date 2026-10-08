# Local MLX model catalog and validation (2026-10-08)

This note records the current on-device model choices and the available Skim-specific evaluation evidence. Model fixture scores are narrow regression signals, not broad quality or faithfulness rankings.

## Catalog

Download sizes are rounded estimates from the [frontend catalog](../../src/lib/aiModels.ts); they are not estimates of runtime memory. Phone gates account for the system API reporting 11.5 GB on some nominal 12 GB devices. Memory-gated new choices remain hidden until physical memory is known, while a saved selection remains visible.

| Model card | Download | Availability |
|---|---:|---|
| [LFM2.5 1.2B Instruct](https://huggingface.co/mlx-community/LFM2.5-1.2B-Instruct-4bit) | 0.7 GB | Phone default; Mac |
| [Qwen3.5 2B](https://huggingface.co/mlx-community/Qwen3.5-2B-4bit) | 1.8 GB | Phone and Mac alternative |
| [Qwen3.5 4B](https://huggingface.co/mlx-community/Qwen3.5-4B-4bit) | 3.1 GB | Mac default; phone with 12 GB-class memory (11.5 GB reported tolerance) |
| [Gemma 4 E2B](https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit) | 3.6 GB | Phone with 12 GB-class memory; Mac |
| [Gemma 4 E4B](https://huggingface.co/mlx-community/gemma-4-e4b-it-4bit) | 5.2 GB | Mac, 16 GB+ |
| [Qwen3.5 9B](https://huggingface.co/mlx-community/Qwen3.5-9B-4bit) | 6.0 GB | Mac, 16 GB+; 24 GB+ recommended |
| [Qwen3.8 27B](https://huggingface.co/mlx-community/Qwen3.8-27B-4bit) | 16.1 GB | Mac, 48 GB+ |
| [Qwen3.6 35B-A3B](https://huggingface.co/mlx-community/Qwen3.6-35B-A3B-4bit) | 20.4 GB | Mac, 48 GB+ |

The October 7 note's earlier defaults, sizes, and memory guidance have been retired; its still-valid runtime behavior is summarized in [the historical implementation note](2026-10-07-on-device-models.md). The active model choices and gates are maintained in `src/lib/aiModels.ts`.

## Skim fixture results

Runs used the synthetic chat and summary fixtures with prefix reuse enabled. All four models passed 7 of 8 chat cases. The failure was a missing calibration/alignment detail in the step-by-step answer for Qwen3 1.7B and both Qwen3.5 models; LFM2.5 failed the bridge yes/no first-sentence check.

| Model | Chat | Summaries | Summary misses |
|---|---:|---:|---|
| Qwen3 1.7B (retired) | 7/8 | 3/6 | Omitted a fragility detail, the bridge's 42.7 cost, and the lead researcher’s name |
| LFM2.5 1.2B | 7/8 | 3/6 | Omitted the 400-nanometer result and fragility detail, the bridge's eleven-week schedule result, and the lead researcher’s name |
| Qwen3.5 2B | 7/8 | 3/6 | Omitted the nozzle detail and lead researcher’s name; one bridge summary introduced the unsupported year 2024 |
| Qwen3.5 4B | 7/8 | 6/6 | No summary fixture misses; its chat miss was the calibration/alignment detail above |

These counts describe the listed synthetic cases only. They do not establish a general winner or production accuracy. The test failure criteria are visible in `shared/fixtures/chat-answer-quality.json` and `shared/fixtures/summary-faithfulness.json`.

## Mac debug-bridge measurements

Runs used a Mac with 128 GB of unified memory. These are debug-build measurements from the same small fixture run and are noisy; they do not measure a physical iPhone. “First token” averages primary requests and their same-article follow-ups; it is not a controlled cold-versus-warm benchmark. Peak memory is the bridge's observed peak for the run.

| Model | Primary first token | Follow-up first token | Decode | Peak memory | Mean chat case |
|---|---:|---:|---:|---:|---:|
| Qwen3 1.7B | 0.254 s | 0.192 s | 30.2 tok/s | 1,701 MB | 2.22 s |
| LFM2.5 1.2B | 0.154 s | 0.085 s | 140.6 tok/s | 1,414 MB | 0.71 s |
| Qwen3.5 2B | 0.488 s | 0.103 s | 41.1 tok/s | 1,984 MB | 3.40 s |
| Qwen3.5 4B | 0.370 s | 0.282 s | 23.6 tok/s | 3,429 MB | 5.15 s |

Raw reports are checked in as [phone and legacy comparison](2026-10-08-phone-model-eval.json) and [Mac 4B comparison](2026-10-08-mac-model-eval.json).

## Prefix reuse

The packaged release helper produced identical deterministic answers with reuse enabled and disabled for LFM2.5, Qwen3.5 4B, and Gemma 4 E2B. Follow-ups reused 987, 1023, and 984 prompt tokens respectively; uncached requests reused zero. [Raw paired results](2026-10-08-prefix-reuse.json). This checks the tested prompt, not all model outputs or sampling settings.

## Build and smoke-check status

- Passing checks: 241 frontend tests, 56 shared inference-policy tests, 15 evaluation tests, 26 native catalog tests on a clean iOS simulator, and an unsigned iOS device build. The focused catalog, picker, and settings tests passed all 39 cases, alongside the TypeScript check and Vite production build.
- Model-load and generation smoke checks passed for LFM2.5 1.2B, Qwen3.5 2B/4B/9B, and Gemma 4 E2B/E4B through the debug helper. [Raw smoke results](2026-10-08-model-load-smoke.json). The packaged release helper also passed the three paired prefix checks above and answered both arithmetic requests with no explicit repo ID, exercising the Mac default.
- All 208 Rust tests passed, including real Qwen3.5 2B Q4_K_M GGUF loading and inference plus a split-token UTF-8 regression. The previous llama-cpp binding (0.1.143) treated the appended MTP block as another recurrent layer and failed on `blk.24.ssm_conv1d.weight`; upgrading to [0.1.159](https://docs.rs/crate/llama-cpp-2/0.1.159) repaired that compatibility. Vocabulary API calls were migrated with the previous tokenization flags and incremental UTF-8 decoding preserved.

The two largest MLX models and their new GGUF equivalents have verified repository metadata and architecture support, but no load or quality run yet. Physical-phone performance remains unmeasured; follow-up issue `skim-eqyq` tracks that work and summary-completeness misses.

The runtime uses [mlx-swift-lm 3.32.3](https://github.com/ml-explore/mlx-swift-lm/releases/tag/3.32.3) (with mlx-swift 0.32.3 and swift-transformers 1.3.4). The model-card links above point to the canonical Hugging Face repositories used by the catalog.
