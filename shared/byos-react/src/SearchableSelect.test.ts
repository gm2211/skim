import assert from 'node:assert/strict';
import test from 'node:test';
import { rankSearchOptions, type SearchOption } from '../dist/SearchableSelect.js';

const options: SearchOption[] = [
  { value: 'gpt-4o-mini', label: 'GPT-4o mini' },
  { value: 'gpt-4.1', label: 'GPT-4.1' },
  { value: 'gpt-4o', label: 'GPT-4o' },
  { value: 'o3', label: 'o3' },
];

test('rankSearchOptions prioritizes exact, word-prefix, prefix, then other matches with stable ties', () => {
  const result = rankSearchOptions(options, 'gpt-4o');
  assert.deepEqual(result.map(option => option.value), ['gpt-4o', 'gpt-4o-mini', 'o3', 'gpt-4.1']);
});

test('rankSearchOptions trims and ignores query case, and preserves original order for blank queries', () => {
  assert.deepEqual(rankSearchOptions(options, '  GPT-4O  ').map(option => option.value), ['gpt-4o', 'gpt-4o-mini', 'o3', 'gpt-4.1']);
  assert.equal(rankSearchOptions(options, '  '), options);
});
