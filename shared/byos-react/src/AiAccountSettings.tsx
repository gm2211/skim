import { useId, useState, type KeyboardEvent, type ReactNode } from 'react';

export type AiAccountSettingsTab = 'model' | 'account' | 'tools';

export type AiAccountSettingsStrings = {
  heading: string;
  changeProvider: string;
  modelTab: string;
  accountTab: string;
  toolsTab: string;
  expiredModelNote: string;
  expiredStatus: string;
  openAccountTab: string;
};

export const defaultAiAccountSettingsStrings: AiAccountSettingsStrings = {
  heading: 'AI settings',
  changeProvider: 'Change AI service',
  modelTab: 'Model',
  accountTab: 'Account',
  toolsTab: 'Tools',
  expiredModelNote: 'Reconnect to use AI.',
  expiredStatus: 'Sign-in expired',
  openAccountTab: 'Account',
};

export type AiAccountSettingsProps = {
  providerName: string;
  headingId?: string;
  expired?: boolean;
  onChangeProvider: () => void;
  modelSettings: ReactNode;
  accountSettings: ReactNode;
  toolsSettings?: ReactNode;
  recoveryAction?: ReactNode;
  strings?: Partial<AiAccountSettingsStrings>;
  className?: string;
  /** Preserve host-owned sign-in/download state while inactive panes stay hidden. */
  keepPanelsMounted?: boolean;
};

export function AiAccountSettings(props: AiAccountSettingsProps) {
  const generatedId = useId();
  const headingId = props.headingId ?? `${generatedId}-heading`;
  const [activeTab, setActiveTab] = useState<AiAccountSettingsTab>('model');
  const strings = { ...defaultAiAccountSettingsStrings, ...props.strings };
  const tabs: { id: AiAccountSettingsTab; label: string; content: ReactNode }[] = [
    { id: 'model', label: strings.modelTab, content: props.modelSettings },
    { id: 'account', label: strings.accountTab, content: <>{props.accountSettings}{props.recoveryAction != null && <div className="byos-account-settings-recovery">{props.recoveryAction}</div>}</> },
    ...(props.toolsSettings == null ? [] : [{ id: 'tools' as const, label: strings.toolsTab, content: props.toolsSettings }]),
  ];
  const active = tabs.find(tab => tab.id === activeTab) ?? tabs[0];
  const activeTabId = `${generatedId}-${active.id}-tab`;
  const panelId = props.keepPanelsMounted ? `${generatedId}-${active.id}-panel` : `${generatedId}-panel`;

  function selectTab(id: AiAccountSettingsTab, focus = false) {
    setActiveTab(id);
    if (focus) window.requestAnimationFrame(() => document.getElementById(`${generatedId}-${id}-tab`)?.focus());
  }

  function onTabKeyDown(event: KeyboardEvent<HTMLDivElement>) {
    const index = tabs.findIndex(tab => tab.id === activeTab);
    let next: number | undefined;
    if (event.key === 'ArrowRight') next = (index + 1) % tabs.length;
    else if (event.key === 'ArrowLeft') next = (index - 1 + tabs.length) % tabs.length;
    else if (event.key === 'Home') next = 0;
    else if (event.key === 'End') next = tabs.length - 1;
    if (next !== undefined) {
      event.preventDefault();
      selectTab(tabs[next].id, true);
    }
  }

  return <section className={`byos byos-account-settings${props.className ? ` ${props.className}` : ''}`} aria-labelledby={headingId}>
    <header className="byos-account-settings-header">
      <h2 id={headingId} tabIndex={-1}>{strings.heading}</h2>
      <div className="byos-account-settings-provider">
        <strong>{props.providerName}</strong>
        {props.expired && <span className="byos-account-settings-status">{strings.expiredStatus}</span>}
        <button type="button" className="byos-account-settings-change" onClick={props.onChangeProvider}>{strings.changeProvider}</button>
      </div>
    </header>
    <div className={`byos-account-settings-tabs byos-account-settings-tabs-${tabs.length}`} role="tablist" aria-label={strings.heading} onKeyDown={onTabKeyDown}>
      {tabs.map(tab => {
        const tabId = `${generatedId}-${tab.id}-tab`;
        return <button key={tab.id} id={tabId} type="button" role="tab" aria-selected={activeTab === tab.id} aria-controls={props.keepPanelsMounted ? `${generatedId}-${tab.id}-panel` : panelId} tabIndex={activeTab === tab.id ? 0 : -1} className="byos-account-settings-tab" onClick={() => selectTab(tab.id)}>{tab.label}</button>;
      })}
    </div>
    {props.keepPanelsMounted ? tabs.map(tab => (
      <div key={tab.id} id={`${generatedId}-${tab.id}-panel`} className="byos-account-settings-panel" role="tabpanel" aria-labelledby={`${generatedId}-${tab.id}-tab`} hidden={active.id !== tab.id}>
        {props.expired && tab.id === 'model' && <p className="byos-account-settings-expired" role="status">
          <span>{strings.expiredModelNote}</span>
          <button type="button" onClick={() => selectTab('account', true)}>{strings.openAccountTab}</button>
        </p>}
        {tab.content}
      </div>
    )) : (
    <div id={panelId} className="byos-account-settings-panel" role="tabpanel" aria-labelledby={activeTabId}>
      {props.expired && activeTab === 'model' && <p className="byos-account-settings-expired" role="status">
        <span>{strings.expiredModelNote}</span>
        <button type="button" onClick={() => selectTab('account', true)}>{strings.openAccountTab}</button>
      </p>}
      {active.content}
    </div>
    )}
  </section>;
}
