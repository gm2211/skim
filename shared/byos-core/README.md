# @byos/core

Framework-free browser pieces of the bring-your-own-subscription kit, extracted from Motive so other
sites can reuse them. Design: https://claude.ai/artifact/1sXmN1AvVjp7jVRefdCShW

- `createCredentialVault({ prefix })`: provider tokens and refresh grants in this tab only
  (`session`) or remembered on this browser (`browser`).
- `createEffortStore({ prefix, recommend })`: per provider+model reasoning effort choice, validated
  against what the provider says the model supports.
- `createModelCatalogCache({ prefix })` and `pickerModels`: the provider's last live model list,
  and the rule that a stale list never drops the user's own selection.
- `ByosProvider` types: the contract each provider adapter implements.

## Token rule

A provider token may cross the site's backend once, only to finish sign-in, and the user is told so.
After that it lives only in the browser and every model call goes browser to provider. Nothing in
this package sends a stored token anywhere; keep it that way.

Every site passes its own non-empty `prefix` (up to 128 characters), so two sites on one origin
never read each other's tokens. Replacing a credential clears any old refresh grant; store a matching
new grant explicitly with `storeRefresh`.
