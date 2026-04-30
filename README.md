# Skim

**RSS reader for the age of AI.** Ingest feeds. Let a model triage the noise. Skim the rest.

<p align="center">
  <img src="docs/skim-demo.gif" alt="Skim — feature highlights" width="820" />
</p>

---

## Install

```bash
pnpm install
pnpm tauri dev
```

Desktop via [Tauri 2](https://tauri.app). macOS / Windows / Linux. iOS / iPadOS in progress.

Full feature list and architecture in [`docs/SPEC.md`](docs/SPEC.md).

[MIT](LICENSE).

---

## AI content notice

Skim is an interface to AI models that **you choose and configure** (Anthropic, OpenAI, OpenRouter, Ollama, local llama.cpp, Apple Foundation Models, etc.). Summaries, chat replies, catch-up reports, and any other AI-generated text are produced by those third-party models — not by Skim.

AI output may be **inaccurate, biased, or hallucinated**. Always verify important details against the original sources. Skim does not produce, endorse, audit, or take responsibility for any AI-generated content. Your use of an AI provider through Skim is governed by that provider's terms and privacy policy.

See the full [Terms of Use](https://gm2211.github.io/skim/terms.html) and [Privacy Policy](https://gm2211.github.io/skim/privacy.html).
