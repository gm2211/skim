# On-device models for summaries and article Q&A (2026-10-07)

Which small models to offer on iPhone and Mac, and what changed to make them faster.

## Candidates

Speeds are third-party measurements with mlx-swift and 4-bit weights (john-rocky/apple-silicon-llm-bench) unless marked. "HHEM" is Vectara's summary hallucination rate; lower is better.

| Model | Download | iPhone 17 Pro speed | Memory | Quality signal | Offered on |
|---|---|---|---|---|---|
| LFM2.5 1.2B Instruct | 0.7 GB | no MLX number (LiteRT int4: 69.5 tok/s) | ~0.7 GB | IFEval 86.2 (vendor) | every iPhone, Mac |
| Qwen3 1.7B (default) | 1.0 GB | 65.1 tok/s, first token 77 ms | ~1.1 GB | HHEM 4.4%, IFEval 68.2 | every iPhone, Mac |
| Qwen3.5 2B | 1.7 GB | 61.2 tok/s, first token 103 ms | 1.3 GB | IFEval 61.2 non-thinking (vendor) | every iPhone, Mac |
| Qwen3 4B Instruct 2507 | 2.3 GB | ~28 tok/s (Qwen3 4B) | ~2.4 GB | HHEM 2.7% (v1), 5.7% (v2): best measured faithfulness | 8 GB iPhones, Mac |
| Qwen3.5 4B | 3.0 GB | none published | | IFEval 89.8, LongBench v2 50.0 (vendor, thinking mode) | 8 GB iPhones, Mac |
| Gemma 4 E2B | 3.6 GB | 47.8 tok/s; 1024-token prompt prefill 2307 tok/s, first token 504 ms | 3.0-3.4 GB | MMLU-Pro 60.0 (vendor) | 8 GB iPhones, Mac |
| Qwen3 8B | 4.6 GB | Mac M4 Max 98 tok/s | | HHEM 4.8% (v2) | Mac 16 GB+ |
| Gemma 4 E4B | 5.2 GB | Mac M4 Max 111 tok/s | | MMLU-Pro 69.4 (vendor) | Mac 16 GB+ |

Retired from the picker (still work if already selected): Gemma 3 1B, LFM2 1.2B, Gemma 3 4B. Gemma 3 1B scored 5/8 on Skim's chat eval against 8/8 for Qwen3 1.7B (docs/releases/2026-09-29-chat-answer-quality.json); LFM2.5 and Gemma 4 replace the other two.

Caveats from the data:
- No faithfulness numbers exist yet for Qwen3.5 small models, Gemma 4 E2B/E4B or LFM2.5. The large Qwen3.5 models score 10.5-12.1% on HHEM against 4.8-5.9% for Qwen3, which is why Qwen3 stays the default until Skim's own eval says otherwise.
- Phi-4 Mini went from 3.4% (HHEM v1) to 23.5% (v2) with long summaries; it stays retired.

## Speed work

- **Article prefix reuse.** Article chat sends the whole article with every question. The model state for the article is now kept between questions, so a follow-up prefills only the question and prior exchange. Plain attention models (Qwen3) rewind the live cache to the shared prefix; models with recurrent or sliding-window layers (Qwen3.5, LFM2.5, Gemma 4) keep a copy taken right after the article. Memory warnings drop it.
- **Model warm-up.** Opening the summary or chat sheet loads the selected model in the background, so the first answer doesn't wait on reading weights.
- **MLX library upgrade** (mlx-swift 0.32.3, mlx-swift-lm 3.32.3, swift-transformers 1.3.4), needed for Qwen3.5, LFM2.5 and Gemma 4, and shared by the iPhone app, the Mac helper and the Tauri plugin through `shared/SkimMLXEngine`.

Considered and rejected:
- **Multi-token prediction for Qwen3.5.** The standard mlx-community conversions strip the MTP weights; measured gains are 1.09-1.2x and vanish on fast small models (mlx-lm PR #990).
- **Gemma 4 drafter models.** At batch size 1, E4B with its drafter ran 39% slower on an M1 Max (29.6 to 18.1 tok/s).
- **KV cache quantization.** Small Qwen3 models are the most sensitive to compressed keys (KL 2.65 at 4 bits on Qwen3 1.7B), and the hybrid models already keep a small cache.

## Measuring it

`tools/SkimChatEval` now scores summary faithfulness (`shared/fixtures/summary-faithfulness.json`: key facts present, no invented claims, no numbers the article never gives, length) next to the 8 chat cases, and reports first-token time cold and on a same-article follow-up, prefill and decode speed, and peak memory. `--no-prefix-reuse` measures the A/B.

```
plugins/tauri-plugin-skim-ai/build-macos-bridge.sh
swift run --package-path tools/SkimChatEval -c release skim-chat-eval \
  --json-out docs/releases/2026-10-07-on-device-eval.json \
  --markdown-out docs/releases/2026-10-07-on-device-eval.md
```

Sources: github.com/vectara/hallucination-leaderboard, github.com/john-rocky/apple-silicon-llm-bench, github.com/ml-explore/mlx-swift-lm (3.32.3), github.com/ml-explore/mlx-lm/pull/990, model cards on huggingface.co (Qwen/Qwen3.5-2B, Qwen/Qwen3.5-4B, google/gemma-4-E2B-it, LiquidAI/LFM2.5-1.2B-Instruct).
