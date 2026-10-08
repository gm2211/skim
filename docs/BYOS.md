# BYOS integration

Skim's React settings use the pinned `@byos/providers` on-device catalog and native-runtime capability filter. `shared/BYOS_REVISION` records the upstream commit. TypeScript and Vite compile the vendored source through `@byos/core` and `@byos/providers` aliases; no extra package build or runtime network access is required.

The binding in `src/lib/aiModels.ts` opts in to engines implemented by Skim's native host. Settings require Tauri's runtime marker before exposing those options; a Mac browser user agent alone does not enable them. Embedded llama.cpp is desktop-only. MLX and Apple Intelligence are Apple-native options. Existing model download and readiness panels still perform engine-specific checks before inference. These options require no BYOS account or subscription.

BYOS also provides a credential-free `createOnDeviceProvider` bridge contract for applications that route inference through its TypeScript adapter. Skim currently shares the catalog and capability filtering only: its Rust llama.cpp/remote-provider implementations, Tauri MLX/Foundation Models bridge, and Swift iOS settings and inference remain Skim-owned. Cloud authentication and inference have not migrated to BYOS. This integration does not change provider policy gates.

Update reusable behavior in [gm2211/byos](https://github.com/gm2211/byos), then sync its reviewed full commit SHA:

```sh
BYOS_REPO=/path/to/byos bash scripts/sync-byos.sh <full-commit-sha>
pnpm test
pnpm build
```

Never patch `shared/byos-*` directly. Host provider choices, native readiness probes, model catalogs/downloads and application UI remain consumer bindings. Browser and hosted-server runtimes receive no BYOS native options. No automatic cloud fallback is introduced.
