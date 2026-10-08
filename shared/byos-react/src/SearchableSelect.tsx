import { useEffect, useId, useMemo, useRef, useState } from 'react';
import { AnchoredMenu } from './AnchoredMenu.js';

export type SearchOption = {
  value: string;
  label: string;
  /** Optional second line shown under the label and included in search matching. */
  meta?: string;
};

export function rankSearchOptions(options: SearchOption[], rawQuery: string): SearchOption[] {
  const needle = rawQuery.trim().toLowerCase();
  if (!needle) return options;
  return options
    .map((option, index) => {
      const label = option.label.toLowerCase();
      const rank = label === needle ? 0 : label.startsWith(`${needle} `) ? 1 : label.startsWith(needle) ? 2 : 3;
      return { option, index, rank };
    })
    .sort((left, right) => left.rank - right.rank || left.option.label.length - right.option.label.length || left.index - right.index)
    .map(({ option }) => option);
}

export type SearchableSelectStrings = {
  optionsLabel: (label: string) => string;
  openOptions: (label: string) => string;
  closeOptions: (label: string) => string;
  noMatches: string;
  typeMoreToNarrow: (count: number) => string;
};

export const defaultSearchableSelectStrings: SearchableSelectStrings = {
  optionsLabel: label => `${label} options`,
  openOptions: label => `Open ${label} options`,
  closeOptions: label => `Close ${label} options`,
  noMatches: 'No matches',
  typeMoreToNarrow: count => `Type more to narrow ${count} options`,
};

export type SearchableSelectProps = {
  value: string;
  options: SearchOption[];
  ariaLabel: string;
  onChange: (value: string) => void;
  compact?: boolean;
  customOption?: (query: string) => SearchOption | undefined;
  portalContainer?: Element;
  strings?: Partial<SearchableSelectStrings>;
  className?: string;
  classNames?: Partial<Record<'field' | 'input' | 'toggle' | 'menu' | 'option' | 'optionMeta', string>>;
};

export function SearchableSelect({ value, options, ariaLabel, onChange, compact = false, customOption, portalContainer, strings, className = '', classNames = {} }: SearchableSelectProps) {
  const labels = { ...defaultSearchableSelectStrings, ...strings };
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState('');
  const [editing, setEditing] = useState(false);
  const [activeIndex, setActiveIndex] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);
  const fieldRef = useRef<HTMLDivElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);
  const listId = useId();
  const selectedLabel = options.find(option => option.value === value)?.label ?? value;
  const filtered = useMemo(() => {
    const needle = editing ? query.trim().toLowerCase() : '';
    if (!needle) return options;
    const matches = rankSearchOptions(
      options.filter(option => `${option.label} ${option.value} ${option.meta ?? ''}`.toLowerCase().includes(needle)),
      needle,
    );
    const custom = customOption?.(query);
    return custom && !options.some(option => option.value.toLowerCase() === custom.value.toLowerCase()) ? [...matches, custom] : matches;
  }, [customOption, editing, options, query]);
  const visibleOptions = filtered.slice(0, 100);

  useEffect(() => setActiveIndex(0), [editing, query, open]);
  useEffect(() => {
    const menu = menuRef.current;
    const active = document.getElementById(`${listId}-${activeIndex}`);
    if (!menu || !active || !menu.contains(active)) return;
    const menuBounds = menu.getBoundingClientRect();
    const activeBounds = active.getBoundingClientRect();
    if (activeBounds.bottom > menuBounds.bottom) menu.scrollTop += activeBounds.bottom - menuBounds.bottom;
    else if (activeBounds.top < menuBounds.top) menu.scrollTop -= menuBounds.top - activeBounds.top;
  }, [activeIndex, listId, open]);

  function close() {
    setOpen(false);
    setEditing(false);
    setQuery('');
  }
  function choose(option: SearchOption) {
    onChange(option.value);
    close();
  }

  return <div
    className={`byos-searchable-select${compact ? ' byos-searchable-select--compact' : ''}${open ? ' byos-searchable-select--open' : ''} ${className}`.trim()}
    onBlur={event => {
      const next = event.relatedTarget as Node | null;
      if (!event.currentTarget.contains(next) && !menuRef.current?.contains(next)) close();
    }}
  >
    <div className={`byos-searchable-select-field ${classNames.field ?? ''}`.trim()} ref={fieldRef}>
      <input
        ref={inputRef}
        className={`byos-searchable-select-input ${classNames.input ?? ''}`.trim()}
        role="combobox"
        aria-label={ariaLabel}
        aria-expanded={open}
        aria-controls={listId}
        aria-autocomplete="list"
        aria-activedescendant={open && visibleOptions[activeIndex] ? `${listId}-${activeIndex}` : undefined}
        title={editing ? undefined : selectedLabel}
        value={editing ? query : selectedLabel}
        onFocus={event => {
          setOpen(true); setEditing(false); setQuery(''); event.currentTarget.select();
        }}
        onClick={event => {
          if (!editing) event.currentTarget.select();
          if (!open) setOpen(true);
        }}
        onChange={event => { setEditing(true); setQuery(event.target.value); setOpen(true); }}
        onKeyDown={event => {
          const startsFreshQuery = !editing && !event.metaKey && !event.ctrlKey && !event.altKey
            && (event.key.length === 1 || event.key === 'Backspace' || event.key === 'Delete');
          if (startsFreshQuery) {
            event.preventDefault(); setEditing(true); setQuery(event.key.length === 1 ? event.key : ''); setOpen(true);
          } else if (event.key === 'ArrowDown') {
            event.preventDefault();
            if (!open) setOpen(true);
            else setActiveIndex(index => Math.min(index + 1, Math.max(0, visibleOptions.length - 1)));
          } else if (event.key === 'ArrowUp') {
            event.preventDefault(); setActiveIndex(index => Math.max(0, index - 1));
          } else if (event.key === 'Enter' && open && visibleOptions[activeIndex]) {
            event.preventDefault(); choose(visibleOptions[activeIndex]);
          } else if (event.key === 'Escape') {
            if (open) {
              event.preventDefault();
              event.stopPropagation();
              close();
            }
          }
        }}
      />
      <button
        type="button"
        className={`byos-searchable-select-toggle ${classNames.toggle ?? ''}`.trim()}
        aria-label={open ? labels.closeOptions(ariaLabel) : labels.openOptions(ariaLabel)}
        aria-expanded={open}
        aria-controls={listId}
        onMouseDown={event => event.preventDefault()}
        onClick={() => {
          if (open) close();
          else { setOpen(true); setEditing(false); setQuery(''); inputRef.current?.focus(); }
        }}
      ><span aria-hidden="true" /></button>
    </div>
    {open && <AnchoredMenu
      anchorRef={fieldRef}
      menuRef={menuRef}
      contentKey={`${visibleOptions.length}:${query}`}
      id={listId}
      role="listbox"
      aria-label={labels.optionsLabel(ariaLabel)}
      className={classNames.menu}
      portalContainer={portalContainer}
    >
      {visibleOptions.length ? visibleOptions.map((option, index) => <button
        id={`${listId}-${index}`}
        type="button"
        role="option"
        aria-selected={option.value === value}
        className={`byos-searchable-option${index === activeIndex ? ' byos-searchable-option--active' : ''}${option.value === value ? ' byos-searchable-option--selected' : ''} ${classNames.option ?? ''}`.trim()}
        key={option.value}
        onMouseDown={event => event.preventDefault()}
        onMouseEnter={() => setActiveIndex(index)}
        onClick={() => choose(option)}
      ><span>{option.label}{option.meta && <small className={`byos-searchable-option-meta ${classNames.optionMeta ?? ''}`.trim()}>{option.meta}</small>}</span>{option.value === value && <b aria-hidden="true">✓</b>}</button>) : <p>{labels.noMatches}</p>}
      {filtered.length > visibleOptions.length && <small>{labels.typeMoreToNarrow(filtered.length)}</small>}
    </AnchoredMenu>}
  </div>;
}
