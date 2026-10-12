# README demo

## Walkthrough video

`docs/skim-walkthrough.mp4` and the `docs/skim-walkthrough.gif` the README shows
are a scripted recording: one continuous session through the app with a visible
pointer and a caption per feature.

```bash
pnpm dev                          # in one shell
pnpm walkthrough                  # records, then encodes the MP4 and GIF
```

`record.mjs` drives the app against the same demo fixtures as the stills, so
it needs no feeds, key or model and comes out the same every run. Frames come
from Chromium's screencast with their paint times, into `.walkthrough/`
(ignored by git); `build-video.mjs` resamples them to a constant frame rate.
To change what the video shows or says, edit `CHAPTERS` in `record.mjs`;
`CHAPTERS=today,reader node scripts/screenshots/record.mjs` records just those
chapters while iterating. `GIF_WIDTH` and `GIF_FPS` trade GIF size for
sharpness. Needs ffmpeg with libx264.

## Stills

The stills are generated the same way. Two steps:

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
