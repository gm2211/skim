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

The docs site carousel (`docs/index.html`) uses stills taken the same way:

```bash
pnpm dev                          # in one shell
pnpm screenshots                  # writes docs/screenshots/*.png
```

`capture.mjs` drives the real app in headless Chromium at a fixed viewport
(1440×900) and device pixel ratio (2), so every slide shares one zoom level and
one crop. It talks to `mock-backend.js` instead of the Rust backend: the Tauri
`invoke` bridge is stubbed before the app boots and answered from the demo data
in `fixtures.js`. That means the captures run anywhere, with no feeds, no API
key, and no model — and they are identical every time.

To change what the stills show, edit `STEPS` in `capture.mjs`. To change the
content on screen, edit `fixtures.js` (and `mock-backend.js` for AI answers),
which also changes the walkthrough.

## Design passes

`polish.mjs` renders the screens a design pass looks at (Today for one day and
for a week back, its cog popover, the reader, the command palette, Ask Skim and
its cog, Settings), each at a fixed viewport and DPR, so two runs can be
compared side by side:

```bash
pnpm dev                                        # in one shell
node scripts/screenshots/polish.mjs out/before  # then change things…
node scripts/screenshots/polish.mjs out/after
```

By default it runs against the demo fixtures. `SKIM_MOCK=0` drives the real
app over the dev bridge instead (see `docs/DEV_BROWSER.md`), and
`SCENES=today-cog,today` limits a run to the scenes named.
