# BYOS integration

Skim's React settings render pinned `@byos/react` components: `AiProviderPicker` replaces the provider dropdown, and `AiAccountSettings` owns the Model, Account and Tools tabs. Existing Skim controls fill their slots; provider changes remain drafts until Save. The pinned `@byos/providers` catalog supplies on-device choices and native-runtime capability filtering. `shared/BYOS_REVISION` records the upstream commit. TypeScript and Vite compile the vendored source through `@byos/core`, `@byos/providers` and `@byos/react` aliases; no extra package build or runtime network access is required.

The binding in `src/lib/aiModels.ts` opts in to engines implemented by Skim's native host. Settings require Tauri's runtime marker before exposing those options; a Mac browser user agent alone does not enable them. Embedded llama.cpp is desktop-only. MLX and Apple Intelligence are Apple-native options. Existing model download and readiness panels still perform engine-specific checks before inference. These options require no BYOS account or subscription.

BYOS also provides a credential-free `createOnDeviceProvider` bridge contract for applications that route inference through its TypeScript adapter. Skim shares the provider picker, settings layout, catalog and capability filtering: its Rust llama.cpp/remote-provider implementations, Tauri MLX/Foundation Models bridge, and Swift iOS settings and inference remain Skim-owned. Cloud authentication and inference have not migrated to BYOS. This integration does not change provider policy gates.

Update reusable behavior in [gm2211/byos](https://github.com/gm2211/byos), then sync its reviewed full commit SHA:

```sh
BYOS_REPO=/path/to/byos bash scripts/sync-byos.sh <full-commit-sha>
pnpm test
pnpm build
```

Never patch `shared/byos-*` directly. Host provider choices, native readiness probes, model catalogs/downloads and provider-specific settings content remain consumer bindings. Browser and hosted-server runtimes receive no BYOS native options. No automatic cloud fallback is introduced.

`src/components/settings/byos-settings.css` maps BYOS tokens to the active Skim theme. Credentials are visible only on Account; model controls are visible only on Model, and summary/inbox preferences live on Tools. Host sign-in/download panes stay mounted while hidden, preserving pending flows; focus returns after closing the provider picker. The native Swift iOS settings screen does not use React and remains outside this integration.
