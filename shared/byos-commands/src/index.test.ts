import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { Script } from 'node:vm';
// Built output: the sources use NodeNext `.js` imports.
import {
  ASK_COMMAND_ID, PALETTE_CSS, askFirst, byosAiCommands, createCommandRegistry, createPaletteController,
  formatShortcutKey, isPaletteShortcut, isQuestionLike, paletteKeyAction, rankCommands, scoreText,
} from '../dist/index.js';
import * as commands from '../dist/index.js';
import type { AskBinding, Command } from '../dist/index.js';

const noop = () => undefined;
const cmd = (id: string, title: string, group: string, keywords: string[] = [], extra: Partial<Command> = {}): Command =>
  ({ id, title, group, keywords, run: noop, ...extra });

// Six of Skim's real palette commands.
const SKIM = [
  cmd('action.catchup', 'Quick Catch-up', 'Actions', ['summary', 'brief']),
  cmd('action.refresh', 'Refresh all feeds', 'Actions', ['reload', 'sync', 'fetch']),
  cmd('settings.open', 'Open Settings', 'Settings', ['preferences']),
  cmd('settings.ai', 'AI Provider settings', 'Settings', ['preferences', 'model', 'api key', 'local']),
  cmd('view.sidebar', 'Hide sidebar', 'View', ['toggle', 'collapse']),
  cmd('go.starred', 'Starred', 'Go to', ['favorites']),
];

const key = (k: string, mods: Partial<KeyboardEvent> = {}) =>
  ({ key: k, metaKey: false, ctrlKey: false, altKey: false, shiftKey: false, ...mods }) as KeyboardEvent;
const tick = (ms = 0) => new Promise(resolve => setTimeout(resolve, ms));
const sync = (run: () => void) => run();

test('ranker finds the intended command for the comparison queries (initials, typo, keyword, cross-field)', () => {
  const cases: Array<[string, string]> = [
    ['qc', 'Quick Catch-up'], ['refrsh', 'Refresh all feeds'], ['ai set', 'AI Provider settings'],
    ['pref', 'Open Settings'], ['model', 'AI Provider settings'], ['fav', 'Starred'],
    ['collapse side', 'Hide sidebar'], ['settings ai', 'AI Provider settings'],
  ];
  for (const [query, title] of cases) assert.equal(rankCommands(SKIM, query)[0]?.title, title, query);
});

test('ranker tiers: exact > prefix > word prefix > substring > initials > typo; no match is -1', () => {
  assert.equal(scoreText('Starred', 'starred'), 1000);
  assert.ok(scoreText('Starred', 'star') > scoreText('Show starred', 'star'));
  assert.ok(scoreText('Show starred', 'star') > scoreText('Unstarred', 'star'));
  assert.ok(scoreText('Quick Catch-up', 'qc') > scoreText('Quick Catch-up', 'qkc'));
  assert.equal(scoreText('Starred', 'xyz'), -1);
  assert.equal(scoreText('Café crème', 'crè'), 600);
  assert.equal(scoreText('Create a saved car search', 'saved cars', false), -1);
  // A typo keeps its letters close together; letters scattered across a long title do not match.
  assert.ok(scoreText('Refresh all feeds', 'refrsh') > 0);
  assert.equal(scoreText('Reviewer conclusion', 'run'), -1);
  assert.equal(scoreText('An audience panel, a blind reviewer panel', 'new'), -1);
});

test('scattered letters match titles only, not long keyword or detail text', () => {
  const commands = [
    cmd('new-hunt', 'Start new hunt', 'Commands', ['new search create'], { detail: 'Create a saved car search' }),
    cmd('shortlist', 'Shortlist', 'Navigate', ['saved cars bookmarks'], { detail: '3 saved cars' }),
  ];
  assert.deepEqual(rankCommands(commands, 'saved cars').map(c => c.id), ['shortlist']);
  assert.deepEqual(rankCommands(commands, 'snh').map(c => c.id), ['new-hunt']);
});

test('ranker keeps the given order for an empty query and for ties, and applies a limit', () => {
  assert.deepEqual(rankCommands(SKIM, '  ').map(c => c.id), SKIM.map(c => c.id));
  const twins = [cmd('a', 'Open', 'X'), cmd('b', 'Open', 'Y')];
  assert.deepEqual(rankCommands(twins, 'open').map(c => c.id), ['a', 'b']);
  assert.equal(rankCommands(SKIM, 's', 2).length, 2);
});

test('question detection puts Ask first for questions and sentences, not for command names', () => {
  assert.ok(isQuestionLike('what did I miss today'));
  assert.ok(isQuestionLike('stars?'));
  assert.ok(!isQuestionLike('settings'));
  assert.ok(askFirst(SKIM, 'how many unread feeds'));
  assert.ok(askFirst(SKIM, 'zzzz'));
  assert.ok(!askFirst(SKIM, 'refresh'));
  assert.ok(isQuestionLike('open settings'));
  assert.ok(!askFirst(SKIM, 'open settings'), 'a command named by the phrase still leads');
  assert.ok(askFirst(SKIM, 'open settings?'));
});

test('open shortcut: ⌘K or Ctrl+K only, not with Shift/Option, repeats, or IME composition', () => {
  assert.ok(isPaletteShortcut(key('k', { metaKey: true })));
  assert.ok(isPaletteShortcut(key('K', { ctrlKey: true })));
  assert.ok(!isPaletteShortcut(key('k', { metaKey: true, shiftKey: true })));
  assert.ok(!isPaletteShortcut(key('k', { metaKey: true, altKey: true })));
  assert.ok(!isPaletteShortcut(key('k', { metaKey: true, repeat: true })));
  assert.ok(!isPaletteShortcut(key('k', { metaKey: true, isComposing: true })));
  assert.ok(!isPaletteShortcut(key('k')));
});

test('in-list keys map to actions and ignore IME composition', () => {
  assert.equal(paletteKeyAction(key('ArrowDown'), false), 'next');
  assert.equal(paletteKeyAction(key('n', { ctrlKey: true }), false), 'next');
  assert.equal(paletteKeyAction(key('p', { ctrlKey: true }), false), 'previous');
  assert.equal(paletteKeyAction(key('Enter'), false), 'run');
  assert.equal(paletteKeyAction(key('Enter', { shiftKey: true }), false), 'ask');
  assert.equal(paletteKeyAction(key('Enter', { metaKey: true }), false), 'askFull');
  assert.equal(paletteKeyAction(key('Backspace'), true), 'back');
  assert.equal(paletteKeyAction(key('Backspace'), false), null);
  assert.equal(paletteKeyAction(key('Home'), false), null, 'Home moves the caret while typing');
  assert.equal(paletteKeyAction(key('Home'), true), 'first');
  assert.equal(paletteKeyAction(key('Enter', { isComposing: true }), false), null);
  assert.equal(paletteKeyAction(key('Enter', { keyCode: 229 }), false), null);
  assert.equal(formatShortcutKey('mod', true), '⌘');
  assert.equal(formatShortcutKey('mod', false), 'Ctrl');
});

test('registry orders sources, replaces by id, and notifies on change', () => {
  const registry = createCommandRegistry();
  let changes = 0;
  registry.subscribe(() => { changes += 1; });
  registry.register({ id: 'b', commands: () => [cmd('b1', 'B', 'B')] });
  const removeA = registry.register({ id: 'a', order: -1, commands: () => [cmd('a1', 'A', 'A')] });
  registry.register({ id: 'b', commands: () => [cmd('b2', 'B2', 'B')] });
  assert.deepEqual(registry.commands().map(c => c.id), ['a1', 'b2']);
  removeA();
  assert.deepEqual(registry.commands().map(c => c.id), ['b2']);
  assert.equal(changes, 4);
});

test('controller browses with groups, searches flat, and hides searchOnly rows and over-limit rows while browsing', () => {
  const registry = createCommandRegistry([
    { id: 'main', commands: () => [...SKIM, cmd('secret', 'Disconnect', 'AI', [], { searchOnly: true })] },
    { id: 'hunts', browseLimit: 1, commands: () => [cmd('h1', 'Hunt one', 'Hunts'), cmd('h2', 'Hunt two', 'Hunts')] },
  ]);
  const palette = createPaletteController({ registry, schedule: sync });
  palette.open();
  let state = palette.getState();
  assert.equal(state.mode, 'browse');
  assert.ok(state.showGroups);
  assert.deepEqual(state.items.map(c => c.id).slice(-2), ['go.starred', 'h1']);
  assert.ok(!state.items.some(c => c.id === 'secret'));
  palette.setQuery('disconnect');
  state = palette.getState();
  assert.equal(state.mode, 'search');
  assert.ok(!state.showGroups);
  assert.equal(state.items[0].id, 'secret');
  palette.setQuery('hunt t');
  assert.equal(palette.getState().items[0].id, 'h2');
});

test('controller caps ranked rows for a query at its limit, in rank order', () => {
  const hunts = Array.from({ length: 30 }, (_, i) => cmd(`h${i}`, `Toyota hunt ${i}`, 'Hunts'));
  const registry = createCommandRegistry([{ id: 'hunts', commands: () => hunts }]);
  const palette = createPaletteController({ registry, schedule: sync, limit: 20 });
  palette.open();
  assert.equal(palette.getState().items.length, 30);
  palette.setQuery('toyota');
  assert.deepEqual(palette.getState().items.map(c => c.id), hunts.slice(0, 20).map(c => c.id));
});

test('controller wraps arrow keys, runs the active command after closing, and keeps stay commands open', () => {
  const ran: string[] = [];
  const registry = createCommandRegistry([{ id: 'x', commands: () => [
    cmd('one', 'One', 'G', [], { run: () => { ran.push('one'); } }),
    cmd('two', 'Two', 'G', [], { stay: true, run: () => { ran.push('two'); } }),
  ] }]);
  let openNow = false;
  const palette = createPaletteController({ registry, schedule: run => { assert.equal(openNow, false, 'closes before running'); run(); }, onOpenChange: open => { openNow = open; } });
  palette.open();
  palette.handleKey(key('ArrowUp'));
  assert.equal(palette.getState().active, 1);
  assert.ok(palette.handleKey(key('Enter')));
  assert.deepEqual(ran, ['two']);
  assert.ok(palette.getState().open);
  palette.handleKey(key('ArrowDown'));
  palette.handleKey(key('Enter'));
  assert.deepEqual(ran, ['two', 'one']);
  assert.equal(palette.getState().open, false);
});

test('controller offers Ask after commands, or first for a question, and shows the answer with follow-up rows', async () => {
  const seen: Array<{ query: string; history: number }> = [];
  const ask: AskBinding = {
    label: 'Ask Skim',
    ask: async (query, { history }) => {
      seen.push({ query, history: history.length });
      return { kind: 'answer', text: `About ${query}`, commands: [cmd('cited.1', 'Cited article', '[1]')] };
    },
  };
  const palette = createPaletteController({ registry: createCommandRegistry([{ id: 's', commands: () => SKIM }]), ask, schedule: sync });
  palette.open();
  palette.setQuery('refresh');
  assert.equal(palette.getState().items[0].id, 'action.refresh');
  assert.equal(palette.getState().items[1].id, ASK_COMMAND_ID);
  palette.setQuery('what did I miss today');
  assert.equal(palette.getState().items[0].id, ASK_COMMAND_ID);
  palette.handleKey(key('Enter'));
  assert.equal(palette.getState().mode, 'pending');
  await tick();
  let state = palette.getState();
  assert.equal(state.mode, 'answered');
  assert.deepEqual(state.history.map(t => t.content), ['what did I miss today', 'About what did I miss today']);
  assert.equal(state.items[0].id, 'cited.1');
  palette.setQuery('and yesterday?');
  palette.handleKey(key('Enter'));
  await tick();
  assert.deepEqual(seen, [{ query: 'what did I miss today', history: 0 }, { query: 'and yesterday?', history: 2 }]);
  assert.equal(palette.getState().history.length, 4);
  palette.handleKey(key('Backspace'));
  state = palette.getState();
  assert.equal(state.mode, 'browse');
  assert.equal(state.history.length, 0);
});

test('Ask results can run a command, filter the list, or hand off an action', async () => {
  const ran: string[] = [];
  const registry = createCommandRegistry([{ id: 's', commands: () => SKIM.map(c => ({ ...c, run: () => { ran.push(c.id); } })) }]);
  const results: Parameters<AskBinding['ask']>[0][] = [];
  let next: Awaited<ReturnType<AskBinding['ask']>> = { kind: 'run', commandId: 'go.starred' };
  const palette = createPaletteController({ registry, schedule: sync, ask: { label: 'Ask', ask: async query => { results.push(query); return next; } } });
  palette.open();
  await palette.ask('show my favourites');
  assert.deepEqual(ran, ['go.starred']);
  assert.equal(palette.getState().open, false);

  next = { kind: 'filter', commandIds: ['settings.ai', 'settings.open', 'gone'], message: 'Two settings pages match.' };
  palette.open();
  await palette.ask('where do I change things');
  let state = palette.getState();
  assert.equal(state.mode, 'filtered');
  assert.deepEqual(state.items.map(c => c.id), ['settings.ai', 'settings.open']);
  assert.equal(state.message, 'Two settings pages match.');
  palette.setQuery('star');
  assert.equal(palette.getState().mode, 'search', 'typing leaves the filter');

  let performed = false;
  next = { kind: 'action', perform: () => { performed = true; } };
  await palette.ask('draft a study');
  assert.ok(performed);
  assert.equal(palette.getState().open, false);
});

test('a failed ask restores the question with the error; closing aborts an ask in flight', async () => {
  let signal: AbortSignal | undefined;
  let fail = true;
  const palette = createPaletteController({
    registry: createCommandRegistry([{ id: 's', commands: () => SKIM }]), schedule: sync,
    ask: { label: 'Ask', ask: (_q, options) => { signal = options.signal; return fail ? Promise.reject(new Error('Connect AI first.')) : new Promise(() => undefined); } },
  });
  palette.open();
  palette.setQuery('why is this slow');
  await palette.ask();
  let state = palette.getState();
  assert.equal(state.mode, 'search');
  assert.equal(state.query, 'why is this slow');
  assert.equal(state.error, 'Connect AI first.');
  fail = false;
  void palette.ask();
  assert.equal(palette.getState().mode, 'pending');
  assert.ok(palette.handleKey(key('Escape')));
  assert.ok(signal?.aborted);
  state = palette.getState();
  assert.equal(state.open, false);
});

test('cancel stops an ask in flight and puts the question back', async () => {
  let signal: AbortSignal | undefined;
  const ask: AskBinding = { label: 'Ask', ask: (_query, options) => { signal = options.signal; return new Promise(() => {}); } };
  const palette = createPaletteController({ registry: createCommandRegistry([{ id: 'main', commands: () => SKIM }]), ask, schedule: sync });
  palette.open();
  palette.setQuery('where is my feed');
  void palette.ask();
  assert.equal(palette.getState().mode, 'pending');
  palette.cancel();
  const state = palette.getState();
  assert.equal(signal?.aborted, true);
  assert.equal(state.mode, 'search');
  assert.equal(state.query, 'where is my feed');
  assert.deepEqual(state.history, []);
  assert.equal(state.items[0].id, 'byos.ask');
});

test('⌘↵ hands the query and history to the full chat after closing', () => {
  const calls: Array<[string, number]> = [];
  const palette = createPaletteController({
    registry: createCommandRegistry(), schedule: sync,
    ask: { label: 'Ask', ask: async () => ({ kind: 'answer', text: '' }), openFull: (query, history) => { calls.push([query, history.length]); } },
  });
  palette.open();
  palette.setQuery('summarize this week');
  assert.ok(palette.handleKey(key('Enter', { metaKey: true })));
  assert.deepEqual(calls, [['summarize this week', 0]]);
  assert.equal(palette.getState().open, false);
});

test('async sources debounce, abort stale lookups, cap rows, skip duplicates, and land after local matches', async () => {
  const queries: string[] = [];
  const aborted: string[] = [];
  const registry = createCommandRegistry([
    { id: 's', commands: () => SKIM },
    { id: 'articles', debounceMs: 5, limit: 2, search: async (query, signal) => {
      queries.push(query);
      signal.addEventListener('abort', () => aborted.push(query));
      await tick(10);
      return [cmd('go.starred', 'Starred', 'Go to'), cmd('a1', `Star ${query}`, 'Articles'), cmd('a2', 'Two', 'Articles'), cmd('a3', 'Three', 'Articles')];
    } },
  ]);
  const palette = createPaletteController({ registry, schedule: sync });
  palette.open();
  palette.setQuery('s');
  palette.setQuery('st');
  palette.setQuery('sta');
  assert.ok(palette.getState().searching);
  await tick(8);
  palette.setQuery('star');
  await tick(30);
  assert.deepEqual(queries, ['sta', 'star']);
  assert.deepEqual(aborted, ['sta']);
  const ids = palette.getState().items.map(c => c.id);
  assert.equal(ids[0], 'go.starred');
  assert.deepEqual(ids.slice(-1), ['a1'], 'limit 2 includes the duplicate, which is dropped');
  assert.equal(palette.getState().searching, false);
});

test('AI commands show only metadata and adapt to connection state', () => {
  const opened: Array<string | undefined> = [];
  let status = { connected: false } as { connected: boolean; expired?: boolean; providerName?: string; modelName?: string };
  const source = byosAiCommands({ status: () => status, openSettings: section => { opened.push(section); }, signOut: noop });
  let rows = source.commands();
  assert.deepEqual(rows.map(r => r.title), ['AI settings', 'Connect AI']);
  rows[1].run();
  assert.deepEqual(opened, ['account']);
  status = { connected: true, providerName: 'ChatGPT', modelName: 'gpt-5' };
  rows = source.commands();
  assert.deepEqual(rows.map(r => r.title), ['AI settings', 'Change AI model', 'Disconnect ChatGPT']);
  assert.equal(rows[0].detail, 'ChatGPT · gpt-5');
  assert.ok(rows[2].searchOnly);
  status = { connected: true, expired: true, providerName: 'Claude' };
  assert.ok(source.commands().some(r => r.title === 'Reconnect Claude'));
  assert.equal(rankCommands(byosAiCommands({ status: () => ({ connected: true }), openSettings: noop }).commands(), 'api key')[0].id, 'byos.ai.settings');
});

test('generated styles are current and every token has a fallback', () => {
  const css = readFileSync(new URL('./styles.css', import.meta.url), 'utf8');
  assert.equal(PALETTE_CSS, css);
  assert.doesNotMatch(css.replace(/^\/\*[^\n]*\*\//, ''), /\$[a-z]/);
  for (const match of css.matchAll(/var\(--byos-[a-z-]+\)/g)) assert.fail(`missing fallback: ${match[0]}`);
});

test('the classic script defines ByosCommands with every export and a working controller', () => {
  const context: { ByosCommands?: typeof commands; setTimeout: typeof setTimeout; clearTimeout: typeof clearTimeout } = { setTimeout, clearTimeout };
  new Script(readFileSync(new URL('../dist/classic.js', import.meta.url), 'utf8')).runInNewContext(context);
  const classic = context.ByosCommands!;
  assert.deepEqual(Object.keys(classic).sort(), Object.keys(commands).sort());
  const registry = classic.createCommandRegistry([{ id: 'main', commands: () => SKIM }]);
  const palette = classic.createPaletteController({ registry, schedule: sync });
  palette.open();
  palette.setQuery('qc');
  assert.equal(palette.getState().items[0].id, 'action.catchup');
});
