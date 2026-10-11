import type { ReactNode } from 'react';

export type AiProviderChoice = {
  id: string;
  name: string;
  badge?: ReactNode;
};

export type AiProviderPickerStrings = {
  label: string;
  selected: string;
};

export const defaultAiProviderPickerStrings: AiProviderPickerStrings = {
  label: 'Choose an AI service',
  selected: 'Selected',
};

export type AiProviderPickerProps = {
  providers: AiProviderChoice[];
  selectedId?: string;
  onSelect: (providerId: string) => void;
  strings?: Partial<AiProviderPickerStrings>;
  className?: string;
};

/** A short, application-owned provider choice list. It does not connect or authenticate providers. */
export function AiProviderPicker(props: AiProviderPickerProps) {
  const strings = { ...defaultAiProviderPickerStrings, ...props.strings };
  return <div className={`byos byos-provider-picker${props.className ? ` ${props.className}` : ''}`} role="group" aria-label={strings.label}>
    {props.providers.map(provider => {
      const selected = provider.id === props.selectedId;
      return <button key={provider.id} type="button" className={`byos-provider-choice${selected ? ' byos-provider-choice-selected' : ''}`} aria-pressed={selected} onClick={() => props.onSelect(provider.id)}>
        <span className="byos-provider-choice-name">{provider.name}</span>
        {provider.badge != null && <span className="byos-provider-choice-badge">{provider.badge}</span>}
        {selected && <span className="byos-provider-choice-selected-label">{strings.selected}</span>}
      </button>;
    })}
  </div>;
}
