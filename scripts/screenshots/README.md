# README demo

`docs/skim-demo.gif` is generated, not recorded. Two steps:

```bash
pnpm dev                          # in one shell
pnpm screenshots                  # captures the frames
pnpm demo                         # encodes docs/skim-demo.gif
```

`capture.mjs` drives the real app in headless Chromium at a fixed viewport
(1440×900) and device pixel ratio (2), so every slide shares one zoom level and
one crop. It talks to `mock-backend.js` instead of the Rust backend: the Tauri
`invoke` bridge is stubbed before the app boots and answered from the demo data
in `fixtures.js`. That means the captures run anywhere, with no feeds, no API
key, and no model — and they are identical every time.

Output:

- `docs/screenshots/*.png` — the raw app shots, also used by the docs site
  carousel in `docs/index.html`.
- `docs/screenshots/frames/*.png` — the same shots with a caption strip,
  composed in the browser so the caption uses real font rendering.
- `docs/skim-demo.gif` — the frames at a uniform hold and crossfade.

To change what the demo shows, edit `STEPS` in `capture.mjs`. To change the
content on screen, edit `fixtures.js`. Slide order follows filename order.

`build-demo.mjs` needs ffmpeg on `PATH`, or `FFMPEG=/path/to/ffmpeg`.

## Design passes

`polish.mjs` renders the screens a design pass looks at (the Quick Catch-up
front page in its empty, reading, filling-in and finished states, Today, the
reader, the command palette, Ask Skim, Settings), each at a fixed viewport and
DPR, so two runs can be compared side by side:

```bash
pnpm dev                                        # in one shell
node scripts/screenshots/polish.mjs out/before  # then change things…
node scripts/screenshots/polish.mjs out/after
```

By default it runs against the demo fixtures. `SKIM_MOCK=0` drives the real
app over the dev bridge instead (see `docs/DEV_BROWSER.md`), and
`SCENES=catchup-page,today` limits a run to the scenes named.
