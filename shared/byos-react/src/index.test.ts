import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';

// Components are exercised in the host app (Motive) in a real browser; here we hold the theming
// contract: every style reads a --byos-* token with a default, and the generated CSS is current.
const source = readFileSync(new URL('./styles.src.css', import.meta.url), 'utf8');
const generated = readFileSync(new URL('./styles.css', import.meta.url), 'utf8');

test('every $token in the source CSS becomes a --byos-* variable with a fallback', () => {
  const tokens = new Set([...source.matchAll(/\$([a-z-]+[a-z])/g)].map(match => match[1]));
  assert.ok(tokens.size > 10);
  for (const token of tokens) assert.match(generated, new RegExp(`var\\(--byos-${token}, [^)]`));
  assert.doesNotMatch(generated.replace(/^\/\*[\s\S]*?\*\//, ''), /\$[a-z]/);
});

test('generated CSS is up to date with its source', () => {
  const strip = (css: string) => {
    let previous = '';
    let current = css;
    while (current !== previous) {
      previous = current;
      current = current.replace(/var\(--byos-([a-z-]+), (?:[^()]|\([^()]*\))*\)/g, '$$$1');
    }
    return current.replace(/^\/\*[^\n]*\*\/\n/, '');
  };
  assert.equal(strip(generated), source.replaceAll('var(--byos-surface-overlay, $surface)', '$surface-overlay'));
});
