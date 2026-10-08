# @byos/react

React UI for the bring-your-own-subscription kit. Design:
https://claude.ai/artifact/1sXmN1AvVjp7jVRefdCShW

- `DeviceCodeSignIn`: one-time-code subscription sign-in (idle, preparing, code, completing, error,
  connected, unavailable), with a remember-on-this-browser toggle and privacy disclosure. Opt into
  compact Sign in, Privacy, and Help tabs for short setup dialogs.
- `ModelEffortPicker`: model and effort from the provider's own list, using the shared searchable
  combobox by default; `renderSelect` preserves an application-owned control when needed.
- `AiPill`: status pill plus quick-settings popover (bottom sheet on phones).
- `AiQuickSettingsPanel`: reusable provider heading, settings action, connection notice, and settings body for `AiPill` or standalone use.
- `AiAccountSettings`: compact provider row and keyboard-accessible Model, Account, and optional Tools tabs. It mounts one pane at a time and places expired-account recovery in Account.
- `AiProviderPicker`: short, application-owned provider choice list; selection does not connect or authenticate a provider.
- `SignInWithChatGPT`: localized identity-only website sign-in presentation with approved black/white OpenAI button formats and availability/status slots. The host supplies the start route and its disclosure.
- `DialogCloseButton`: accessible 44px close control for host-owned dialogs; the caller handles placement and dismissal.
- `useProviderModels`, `useEffortChoice`: headless hooks over `@byos/core`.

## Theming

Import `@byos/react/styles.css`, then point the tokens at your design system:

```css
.checkout-ai {
  --byos-font: var(--my-sans);
  --byos-font-mono: var(--my-mono);
  --byos-text: var(--my-text);
  --byos-muted: var(--my-muted);
  --byos-faint: var(--my-subtle);
  --byos-surface: var(--my-panel);
  --byos-surface-soft: var(--my-panel-soft);
  --byos-surface-raised: var(--my-panel-raised);
  --byos-surface-input: var(--my-input);
  --byos-line: var(--my-border);
  --byos-line-strong: var(--my-border-strong);
  --byos-accent: var(--my-brand);
  --byos-accent-strong: var(--my-brand-hover);
  --byos-on-accent: white;
  --byos-success: var(--my-success);
  --byos-warning: var(--my-warning);
  --byos-warning-soft: var(--my-warning-soft);
  --byos-danger: var(--my-danger);
  --byos-radius: 8px;
  --byos-radius-lg: 14px;
  --byos-shadow: var(--my-popover-shadow);
}
```

Set variables on an ancestor to theme each component, or on one wrapper to theme that section.
On mobile, `AiPill` portals its sheet to `document.body`; set tokens there or pass
`portalContainer` pointing to a themed overlay root outside clipped containers.
Unspecified variables use the neutral defaults. The full token list is font, font-mono, text, muted,
faint, surface, surface-soft, surface-raised, surface-input, surface-overlay, surface-backdrop,
line, line-strong, accent, accent-strong, on-accent, success, warning, warning-soft, danger,
secondary-fill, secondary-border, secondary-hover, pill-fill, pill-border, pill-text, radius,
radius-lg, and shadow
(each uses the `--byos-` prefix).

Use `className` on `DeviceCodeSignIn` and `AiPill`; `ModelEffortPicker` also supports the `root`,
`field`, `note`, and `retry` class names. `AiPill` supports button, prefix, label, popover, and
backdrop class names. These can scope app-specific CSS while preserving the package defaults.

`DeviceCodeSignIn`, `ModelEffortPicker`, `AiQuickSettingsPanel`, `AiAccountSettings`, and `AiProviderPicker` localize UI copy through their `strings` props. `DeviceCodeSignIn` accepts an optional `headingId` for dialog focus management and `compact` for a tabbed presentation. In compact mode, Remember and full privacy details appear on Privacy; code, approval, progress, and cancel stay on Sign in; Help carries sign-in guidance. The short disclosure appears before initial sign-in and is omitted while waiting. ArrowLeft/ArrowRight, Home, and End move between tabs. The default presentation remains unchanged.
`AiPill` uses the explicit label props listed below. For example:

```tsx
<ModelEffortPicker
  {...pickerProps}
  strings={{
    model: 'MODELO',
    modelAriaLabel: 'Seleccionar modelo',
    effort: 'RAZONAMIENTO',
    effortAriaLabel: 'Seleccionar nivel de razonamiento',
  }}
/>

<DeviceCodeSignIn
  {...signInProps}
  providerName="Acme AI"
  strings={{ connectTitle: 'Connect Acme', connectButton: 'Continue with Acme' }}
/>
```

`AiPill` exposes `setupLabel`, `prefix`, and `popoverLabel`, plus `setupAriaLabel` and `ariaLabel`
for localized accessible names. The default searchable picker accepts `portalContainer` when its
menu needs to stay inside a themed overlay root; use `renderSelect` when an application owns the
control itself. Edit `src/styles.src.css` and run `npm run css` only when changing
the package's default CSS; the generated `src/styles.css` is the file consumers import.

`AiQuickSettingsPanel` accepts `connection` as `connected`, `expired`, `disconnected`, or `tools-only`.
It owns the provider header, settings action, state copy, and content spacing; pass an optional
`reconnectAction` for expired connections. `defaultAiQuickSettingsStrings` provides the English
defaults. It does not perform authentication or select providers.

`AiAccountSettings` keeps the selected provider visible and exposes a 44px **Change AI service**
action. Model is the initial tab. Account and Tools appear only when their content is supplied;
ArrowLeft/ArrowRight, Home, and End move between tabs. Only the active tab panel is mounted.
When `expired` is true, Model shows a short link to Account and `recoveryAction` appears inside
Account. Provider changes, account controls, and tool actions remain application callbacks/content.
`AiProviderPicker` renders a short list of provider actions with optional badges and selected state;
`onSelect` reports an id and never starts authentication.

```tsx
<AiAccountSettings
  providerName="Example AI"
  expired={connectionExpired}
  onChangeProvider={openProviderPicker}
  modelSettings={<ModelEffortPicker {...pickerProps} />}
  accountSettings={<AccountControls />}
  toolsSettings={<ToolControls />}
  recoveryAction={<button onClick={reconnect}>Reconnect</button>}
/>

<AiProviderPicker
  providers={[{ id: 'example', name: 'Example AI', badge: 'Plan' }]}
  selectedId={providerId}
  onSelect={setProviderId}
/>
```

React 18 and 19 are supported, including nullable DOM refs in menus and popovers. React is a peer dependency. When consuming this package through a `file:` link, dedupe React in
your bundler (Vite: `resolve.dedupe: ['react', 'react-dom']`).


`SignInWithChatGPT` renders a 44px native link to the host's website OIDC start route, or a disabled button when `status="unavailable"`. `variant="black" | "white"` selects an approved monochrome sign-in button and bundled official OpenAI vector mark. `onStart` runs synchronously for a normal primary click before the browser follows `href`; pending, success, and unavailable states disable the action. Its inline vector path is taken directly from the official white and black marks in [OpenAI’s website sign-in button assets](https://developers.openai.com/assets/siwc/sign-in-buttons/). Localize `heading`, `description`, button, and state labels through `strings`; provide a product-specific `disclosure` that separates ChatGPT identity from plan usage. The component does not start OAuth itself and does not imply that identity grants ChatGPT subscription usage.

`DeviceCodeSignIn` accepts `signInBrand="chatgpt"` when a provider's device-code flow should use ChatGPT's official monochrome mark and black button styling. This changes presentation only: the existing localized Connect/Try again labels, `onStart` callback, and device-code approval flow remain in effect. It does not represent website identity sign-in or connect the account through OpenID.

```tsx
<SignInWithChatGPT
  href="/auth/chatgpt/start"
  status={identitySignInEnabled ? 'idle' : 'unavailable'}
  message={identitySignInEnabled ? undefined : 'ChatGPT sign-in is not enabled for this app.'}
  disclosure={<p>ChatGPT identity signs in to this app. It does not connect an AI plan.</p>}
/>
```

Set `AiAccountSettings.keepPanelsMounted` for host-owned sign-in or download workflows that must survive tab changes. Inactive panels use HTML `hidden`, with distinct panel IDs and matching `aria-controls`; default behavior still mounts only the active pane.
