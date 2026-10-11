import assert from 'node:assert/strict';
import test from 'node:test';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { AiPill } from '../dist/AiPill.js';
import { ModelEffortPicker } from '../dist/ModelEffortPicker.js';
import { AiQuickSettingsPanel } from '../dist/AiQuickSettingsPanel.js';
import { AiAccountSettings } from '../dist/AiAccountSettings.js';
import { AiProviderPicker } from '../dist/AiProviderPicker.js';
import { DeviceCodeSignIn } from '../dist/DeviceCodeSignIn.js';
import { SignInWithChatGPT } from '../dist/SignInWithChatGPT.js';

test('AiAccountSettings starts on Model, exposes provider switching, and mounts one settings pane', () => {
  const html = renderToStaticMarkup(createElement(AiAccountSettings, {
    providerName: 'Acme AI', onChangeProvider: () => undefined,
    modelSettings: createElement('p', null, 'Model controls'),
    accountSettings: createElement('p', null, 'Remember and disconnect'),
    toolsSettings: createElement('p', null, 'Tool access'),
  }));
  assert.match(html, /AI settings/);
  assert.match(html, /Change AI service/);
  assert.match(html, /aria-selected="true" aria-controls="_R_.*-panel"/);
  assert.match(html, /Model controls/);
  assert.doesNotMatch(html, /Remember and disconnect|Tool access/);
});

test('AiAccountSettings keeps expired recovery in Account and gives Model a compact route to it', () => {
  const html = renderToStaticMarkup(createElement(AiAccountSettings, {
    providerName: 'Acme AI', expired: true, onChangeProvider: () => undefined,
    modelSettings: createElement('p', null, 'Model controls'),
    accountSettings: createElement('p', null, 'Account controls'),
    recoveryAction: createElement('button', null, 'Reconnect'),
  }));
  assert.match(html, /Reconnect to use AI\./);
  assert.match(html, />Account<\/button>/);
  assert.doesNotMatch(html, />Reconnect<\/button>/);
});

test('AiProviderPicker labels provider choices and marks the selected option', () => {
  const html = renderToStaticMarkup(createElement(AiProviderPicker, {
    providers: [{ id: 'a', name: 'Acme', badge: 'Plan' }, { id: 'b', name: 'Beta' }],
    selectedId: 'a', onSelect: () => undefined,
  }));
  assert.match(html, /aria-label="Choose an AI service"/);
  assert.match(html, /aria-pressed="true"/);
  assert.match(html, /Plan/);
  assert.match(html, /aria-pressed="false"/);
});

test('DeviceCodeSignIn exposes an optional focusable dialog heading', () => {
  const html = renderToStaticMarkup(createElement(DeviceCodeSignIn, {
    providerName: 'Acme', headingId: 'guided-start-heading', status: 'idle', device: null,
    connected: false, onStart: () => undefined, onCancel: () => undefined, onDisconnect: () => undefined,
  }));
  assert.match(html, /<h3 id="guided-start-heading" tabindex="-1">Connect your Acme account<\/h3>/);
  assert.doesNotMatch(html, /role="tablist"/);
});

test('compact DeviceCodeSignIn keeps pending actions visible and moves disclosure and account details to tabs', () => {
  const html = renderToStaticMarkup(createElement(DeviceCodeSignIn, {
    providerName: 'Acme', compact: true, status: 'pending', device: { deviceAuthId: 'demo', userCode: 'ABCD-EFGH', verificationUriComplete: 'https://example.test/approve' },
    connected: false, disclosure: 'Short privacy note', remember: { checked: false, onChange: () => undefined },
    privacyDetails: createElement('p', null, 'Full privacy details'), onStart: () => undefined, onCancel: () => undefined, onDisconnect: () => undefined,
  }));
  assert.match(html, /role="tablist"/);
  assert.match(html, /role="tab" aria-selected="true"/);
  assert.match(html, /ABCD-EFGH/);
  assert.match(html, /Continue at Acme/);
  assert.match(html, /Waiting for approval/);
  assert.match(html, /Cancel sign-in/);
  assert.doesNotMatch(html, /Short privacy note|Full privacy details|Remember on this browser/);
});

test('compact DeviceCodeSignIn shows initial disclosure and compact error recovery', () => {
  const initialHtml = renderToStaticMarkup(createElement(DeviceCodeSignIn, {
    providerName: 'Acme', compact: true, status: 'idle', device: null,
    connected: false, disclosure: 'Short privacy note', onStart: () => undefined, onCancel: () => undefined, onDisconnect: () => undefined,
  }));
  assert.match(initialHtml, /Short privacy note/);
  assert.match(initialHtml, /Connect Acme/);
  const errorHtml = renderToStaticMarkup(createElement(DeviceCodeSignIn, {
    providerName: 'Acme', compact: true, status: 'error', device: null, error: 'Code expired',
    connected: false, disclosure: 'Short privacy note', onStart: () => undefined, onCancel: () => undefined, onDisconnect: () => undefined,
  }));
  assert.doesNotMatch(errorHtml, /Short privacy note/);
  assert.match(errorHtml, /Code expired/);
  assert.match(errorHtml, /Try again/);
  assert.match(errorHtml, /Privacy/);
  assert.match(errorHtml, /Help/);
});

test('ChatGPT-branded device-code start and retry actions keep the device flow actionable in both layouts', () => {
  for (const compact of [false, true]) {
    const idle = renderToStaticMarkup(createElement(DeviceCodeSignIn, {
      providerName: 'ChatGPT', signInBrand: 'chatgpt', compact, status: 'idle', device: null,
      connected: false, onStart: () => undefined, onCancel: () => undefined, onDisconnect: () => undefined,
    }));
    assert.match(idle, /byos-chatgpt-identity-button byos-chatgpt-identity-black/);
    assert.match(idle, /<svg[^>]*viewBox="0 0 21 21"[^>]*aria-hidden="true"/);
    assert.match(idle, /<button[^>]*type="button"[^>]*>.*Connect ChatGPT/s);
    assert.doesNotMatch(idle, /disabled/);
    assert.doesNotMatch(idle, /Sign in with ChatGPT|Continue with ChatGPT/);

    const retry = renderToStaticMarkup(createElement(DeviceCodeSignIn, {
      providerName: 'ChatGPT', signInBrand: 'chatgpt', compact, status: 'error', device: null,
      error: 'Sign-in expired', connected: false,
      onStart: () => undefined, onCancel: () => undefined, onDisconnect: () => undefined,
    }));
    assert.match(retry, /<button[^>]*type="button"[^>]*>.*Try again/s);
    assert.doesNotMatch(retry, /disabled/);
    assert.match(retry, /byos-chatgpt-identity-button byos-chatgpt-identity-black/);
  }

  let started = 0;
  const rendered = DeviceCodeSignIn({
    providerName: 'ChatGPT', signInBrand: 'chatgpt', status: 'idle', device: null, connected: false,
    onStart: () => { started += 1; }, onCancel: () => undefined, onDisconnect: () => undefined,
  });
  const findStartButton = (node: unknown): { props: { onClick?: () => void } } | undefined => {
    if (Array.isArray(node)) return node.map(findStartButton).find(Boolean);
    if (!node || typeof node !== 'object') return undefined;
    const element = node as { type?: unknown; props?: { children?: unknown; onClick?: () => void } };
    if (element.type === 'button' && element.props?.onClick) return { props: element.props };
    if (typeof element.type === 'function') return findStartButton((element.type as (props: unknown) => unknown)(element.props));
    return findStartButton(element.props?.children);
  };
  findStartButton(rendered)?.props.onClick?.();
  assert.equal(started, 1);
});

test('compact DeviceCodeSignIn can hide redundant identity and reveal help only for pending and error states', () => {
  const base = {
    providerName: 'Acme', compact: true, showProviderIdentity: false, helpMode: 'contextual' as const,
    connected: false, onStart: () => undefined, onCancel: () => undefined, onDisconnect: () => undefined,
  };
  const idleHtml = renderToStaticMarkup(createElement(DeviceCodeSignIn, { ...base, status: 'idle', device: null }));
  assert.match(idleHtml, /role="tablist"[^>]*>[\s\S]*?<\/div>/);
  assert.equal((idleHtml.match(/role="tab"/g) ?? []).length, 2);
  assert.doesNotMatch(idleHtml, /class="byos-signin-provider"|Subscription|>Help<|Having trouble/);
  assert.match(idleHtml, /aria-selected="true" aria-controls=/);
  assert.match(idleHtml, /tabindex="-1"/);

  const pendingHtml = renderToStaticMarkup(createElement(DeviceCodeSignIn, {
    ...base, status: 'pending', device: { deviceAuthId: 'demo', userCode: 'ABCD-EFGH', verificationUriComplete: 'https://example.test/approve' },
  }));
  assert.equal((pendingHtml.match(/role="tab"/g) ?? []).length, 2);
  assert.match(pendingHtml, /<details class="byos-signin-help"><summary>Having trouble signing in\?<\/summary><p>Keep this tab open while you approve the code\.<\/p><\/details>/);

  const errorHtml = renderToStaticMarkup(createElement(DeviceCodeSignIn, { ...base, status: 'error', device: null, error: 'Code expired' }));
  assert.equal((errorHtml.match(/role="tab"/g) ?? []).length, 2);
  assert.match(errorHtml, /Code expired/);
  assert.match(errorHtml, /Try signing in again/);
  assert.doesNotMatch(errorHtml, /Keep this tab open/);
});

test('AiQuickSettingsPanel exposes the provider, settings action, expired notice, and recovery slot', () => {
  const html = renderToStaticMarkup(createElement(AiQuickSettingsPanel, {
    providerName: 'Acme AI', connection: 'expired', onOpenSettings: () => undefined,
    reconnectAction: createElement('button', null, 'Reconnect'), children: createElement('p', null, 'Model settings'),
  }));
  assert.match(html, /Acme AI/);
  assert.match(html, /All AI settings/);
  assert.match(html, /sign-in expired/);
  assert.match(html, /Reconnect/);
  assert.match(html, /Model settings/);
});

test('AiQuickSettingsPanel omits model content when the account is unavailable for model use', () => {
  for (const connection of ['disconnected', 'tools-only'] as const) {
    const html = renderToStaticMarkup(createElement(AiQuickSettingsPanel, {
      providerName: 'Acme AI', connection, onOpenSettings: () => undefined,
      children: createElement('p', null, 'Model settings'),
    }));
    assert.doesNotMatch(html, /Model settings/);
  }
});

test('ModelEffortPicker keeps default accessible names on its searchable controls', () => {
  const html = renderToStaticMarkup(createElement(ModelEffortPicker, {
    providerName: 'Acme',
    models: [{ value: 'model-1', label: 'Model One' }],
    model: 'model-1',
    onModelChange: () => undefined,
    efforts: [{ value: 'low', label: 'Low' }],
    effort: 'low',
    onEffortChange: () => undefined,
  }));

  assert.match(html, /role="combobox" aria-label="Model"/);
  assert.match(html, /role="combobox" aria-label="Effort"/);
});

test('ModelEffortPicker applies localized accessible names to native selects', () => {
  const html = renderToStaticMarkup(createElement(ModelEffortPicker, {
    providerName: 'Acme',
    models: [{ value: 'model-1', label: 'Modelo Uno' }],
    model: 'model-1',
    onModelChange: () => undefined,
    efforts: [],
    effort: '',
    onEffortChange: () => undefined,
    strings: { model: 'MODELO', modelAriaLabel: 'Seleccionar modelo', effort: 'NIVEL', effortAriaLabel: 'Seleccionar nivel' },
  }));

  assert.match(html, /aria-label="Seleccionar modelo"/);
  assert.match(html, /aria-label="Seleccionar nivel"/);
  assert.match(html, /<span>MODELO/);
  assert.match(html, /<span>NIVEL/);
});

test('AiPill keeps default setup and connected accessible names', () => {
  const setupHtml = renderToStaticMarkup(createElement(AiPill, {
    connected: false,
    label: 'gpt-6 · low',
    onSetup: () => undefined,
    children: () => null,
  }));
  const connectedHtml = renderToStaticMarkup(createElement(AiPill, {
    connected: true,
    label: 'gpt-6 · low',
    onSetup: () => undefined,
    children: () => null,
  }));

  assert.match(setupHtml, /aria-label="Set up AI"/);
  assert.match(connectedHtml, /aria-label="AI: gpt-6 · low\. Change model or effort"/);
});

test('AiPill applies localized accessible names in setup and connected states', () => {
  const setupHtml = renderToStaticMarkup(createElement(AiPill, {
    connected: false,
    label: 'modelo · bajo',
    setupAriaLabel: 'Configurar IA',
    onSetup: () => undefined,
    children: () => null,
  }));
  const connectedHtml = renderToStaticMarkup(createElement(AiPill, {
    connected: true,
    label: 'modelo · bajo',
    ariaLabel: 'Cambiar modelo y razonamiento',
    onSetup: () => undefined,
    children: () => null,
  }));

  assert.match(setupHtml, /aria-label="Configurar IA"/);
  assert.match(connectedHtml, /aria-label="Cambiar modelo y razonamiento"/);
});

test('translating visible picker labels also translates accessible names by default', () => {
  const html = renderToStaticMarkup(createElement(ModelEffortPicker, {
    providerName: 'Acme', models: [], model: '', onModelChange: () => undefined,
    efforts: [], effort: '', onEffortChange: () => undefined,
    strings: { model: 'Modelo', effort: 'Razonamiento' },
  }));
  assert.match(html, /aria-label="Modelo"/);
  assert.match(html, /aria-label="Razonamiento"/);
});


test('SignInWithChatGPT presents the approved route, identity-only disclosure, and disabled state accessibly', () => {
  const html = renderToStaticMarkup(createElement(SignInWithChatGPT, {
    href: '/auth/chatgpt/start', variant: 'white', status: 'idle',
    disclosure: 'ChatGPT identity signs in to this app only.',
  }));
  assert.match(html, /Continue with ChatGPT/);
  assert.match(html, /href="\/auth\/chatgpt\/start"/);
  assert.match(html, /<svg[^>]*viewBox="0 0 21 21"[^>]*aria-hidden="true"/);
  assert.doesNotMatch(html, /chatgpt-logo-(black|white)\.svg/);
  assert.match(html, /ChatGPT identity signs in to this app only/);
  assert.match(html, /aria-labelledby="byos-chatgpt-identity-/);

  const unavailable = renderToStaticMarkup(createElement(SignInWithChatGPT, {
    href: '/auth/chatgpt/start', status: 'unavailable', message: 'ChatGPT sign-in is not enabled.',
  }));
  assert.match(unavailable, /<button[^>]*disabled/);
  assert.match(unavailable, /role="status"/);
  assert.doesNotMatch(unavailable, /href="\/auth\/chatgpt\/start"/);

  for (const status of ['pending', 'success'] as const) {
    const inactive = renderToStaticMarkup(createElement(SignInWithChatGPT, { href: '/auth/chatgpt/start', status }));
    assert.match(inactive, /<button[^>]*disabled/);
    assert.doesNotMatch(inactive, /href="\/auth\/chatgpt\/start"/);
  }
});


test('kept settings panes are hidden and each tab controls its own panel', () => {
  const html = renderToStaticMarkup(createElement(AiAccountSettings, {
    providerName: 'Local', onChangeProvider: () => undefined, keepPanelsMounted: true,
    modelSettings: 'model pane', accountSettings: 'account pane', toolsSettings: 'tools pane',
  }));
  assert.match(html, /model pane/);
  assert.match(html, /account pane/);
  assert.match(html, /tools pane/);
  const panels = [...html.matchAll(/<div id="([^"]+)"[^>]*role="tabpanel"[^>]*>/g)];
  assert.equal(panels.length, 3);
  assert.equal(panels.filter(panel => panel[0].includes('hidden=""')).length, 2);
  for (const panel of panels) assert.ok(html.includes(`aria-controls="${panel[1]}"`));
});
