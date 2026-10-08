import type { ReactNode } from 'react';
import { SearchableSelect } from './SearchableSelect.js';

/**
 * The exact model and effort, both from the provider's own model list. `renderSelect` lets a site
 * drop in its own searchable select; the default is the shared searchable combobox.
 */
export type PickerOption = { value: string; label: string; meta?: string };
export type SelectRenderer = (props: { ariaLabel: string; value: string; options: PickerOption[]; onChange: (value: string) => void }) => ReactNode;

export type ModelEffortPickerStrings = {
  model: string;
  effort: string;
  /** Accessible names for the select controls. Defaults follow the visible field labels. */
  modelAriaLabel: string;
  effortAriaLabel: string;
  effortFrom: (providerName: string) => string;
  noEffort: (providerName: string) => string;
  providerDefault: string;
  remembered: (providerName: string) => string;
  fallback: (providerName: string) => string;
  retry: string;
};

export const defaultModelEffortStrings: ModelEffortPickerStrings = {
  model: 'MODEL',
  effort: 'EFFORT',
  modelAriaLabel: 'Model',
  effortAriaLabel: 'Effort',
  effortFrom: name => `from ${name}`,
  noEffort: name => `${name} chooses effort for this model.`,
  providerDefault: 'Provider default',
  remembered: name => `Using ${name}'s last model list.`,
  fallback: name => `Using a fallback list for ${name}; it may be out of date.`,
  retry: 'Retry',
};

export type ModelEffortPickerProps = {
  providerName: string;
  models: PickerOption[];
  model: string;
  onModelChange: (value: string) => void;
  /** Short note beside MODEL, e.g. "12 from Grok". */
  modelNote?: ReactNode;
  efforts: PickerOption[];
  effort: string;
  onEffortChange: (value: string) => void;
  /** 'remembered': last live answer; 'fallback': never reached the provider. */
  staleness?: 'live' | 'remembered' | 'fallback';
  onRetry?: () => void;
  renderSelect?: SelectRenderer;
  /** Theme the default searchable menu when the picker is rendered in a portal. */
  portalContainer?: Element;
  strings?: Partial<ModelEffortPickerStrings>;
  classNames?: { root?: string; field?: string; note?: string; retry?: string };
};

export function ModelEffortPicker(props: ModelEffortPickerProps) {
  const s = { ...defaultModelEffortStrings, ...props.strings };
  s.modelAriaLabel = props.strings?.modelAriaLabel ?? props.strings?.model ?? defaultModelEffortStrings.modelAriaLabel;
  s.effortAriaLabel = props.strings?.effortAriaLabel ?? props.strings?.effort ?? defaultModelEffortStrings.effortAriaLabel;
  const c = props.classNames ?? {};
  const select = props.renderSelect ?? (selectProps => <SearchableSelect {...selectProps} compact portalContainer={props.portalContainer} />);
  const field = c.field ?? 'byos-field';
  const note = c.note ?? 'byos-note';
  const stale = props.staleness === 'remembered' || props.staleness === 'fallback';
  return <div className={c.root ?? 'byos byos-model-effort'}>
    <div className={field}>
      <span>{s.model} {props.modelNote && <small>{props.modelNote}</small>}</span>
      {select({ ariaLabel: s.modelAriaLabel, value: props.model, options: props.models, onChange: props.onModelChange })}
    </div>
    {/* Effort is its own setting, always shown: a model without selectable levels still says so in
        the same place, rather than the field disappearing into a note under the model. */}
    <div className={field}>
      <span>{s.effort} {props.efforts.length > 0 && <small>{s.effortFrom(props.providerName)}</small>}</span>
      {props.efforts.length > 0
        ? select({ ariaLabel: s.effortAriaLabel, value: props.effort, options: props.efforts, onChange: props.onEffortChange })
        : select({ ariaLabel: s.effortAriaLabel, value: '', options: [{ value: '', label: s.providerDefault }], onChange: () => undefined })}
      {props.efforts.length === 0 && <p className={note}>{s.noEffort(props.providerName)}</p>}
    </div>
    {stale && <div className="byos-picker-stale"><p className={note}>{props.staleness === 'remembered' ? s.remembered(props.providerName) : s.fallback(props.providerName)}</p>{props.onRetry && <button type="button" className={c.retry ?? 'byos-secondary-button'} onClick={props.onRetry}>{s.retry}</button>}</div>}
  </div>;
}
