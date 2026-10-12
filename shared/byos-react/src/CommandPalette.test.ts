import assert from 'node:assert/strict';
import test from 'node:test';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { CommandPaletteButton, CommandPaletteProvider, useCommands } from '../dist/CommandPalette.js';

// Palette behavior (ranking, keys, Ask) is tested in @byos/commands; here we hold the React contract.
test('CommandPaletteProvider renders its children and a closed, labelled dialog', () => {
  const html = renderToStaticMarkup(createElement(CommandPaletteProvider, { strings: { dialogLabel: 'Skim commands' } },
    createElement('main', null, 'App')));
  assert.match(html, /<main>App<\/main>/);
  assert.match(html, /<dialog class="byos-palette" aria-label="Skim commands"><\/dialog>/);
});

test('CommandPaletteButton exposes the shortcut and a localized label', () => {
  const html = renderToStaticMarkup(createElement(CommandPaletteProvider, { strings: { trigger: 'Befehle' } },
    createElement(CommandPaletteButton)));
  assert.match(html, /class="byos-palette-trigger" aria-keyshortcuts="Meta\+K Control\+K"/);
  assert.match(html, /<span>Befehle<\/span>/);
  assert.match(html, /<kbd aria-hidden="true">(⌘ K|Ctrl K)<\/kbd>/);
});

test('useCommands outside a provider explains what is missing', () => {
  const Orphan = () => { useCommands({ id: 'x', commands: () => [] }, []); return null; };
  assert.throws(() => renderToStaticMarkup(createElement(Orphan)), /CommandPaletteProvider/);
});
