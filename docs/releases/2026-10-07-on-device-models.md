# On-device model runtime (2026-10-07)

The candidate rankings, defaults, download sizes, and memory recommendations recorded in the original version of this note were superseded by the October 8 catalog and validation. See [the current local-model catalog and validation](2026-10-08-local-model-validation.md) for those details.

The runtime work from this change remains relevant:

- Article chat reuses the cached article prefix across follow-up questions. Plain-attention models rewind to the shared prefix; recurrent and sliding-window models keep a snapshot taken after the article. Memory warnings clear the snapshot.
- Opening the summary or chat sheet warms the selected model in the background.
- The native app, Mac helper, and Tauri plugin share `SkimMLXEngine`. The MLX Swift LM dependency is pinned at [3.32.3](https://github.com/ml-explore/mlx-swift-lm/releases/tag/3.32.3), alongside mlx-swift 0.32.3 and swift-transformers 1.3.4.

The evaluation harness is in `tools/SkimChatEval`; it reports chat and summary fixture results, primary-request and follow-up timing, prefill and decode throughput, and peak memory. These fixture scores measure the checked cases only and do not establish broad model quality or phone performance.
