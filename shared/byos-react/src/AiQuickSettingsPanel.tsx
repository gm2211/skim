import type { ReactNode } from 'react';

export type AiQuickSettingsConnection = 'connected' | 'expired' | 'disconnected' | 'tools-only';

export type AiQuickSettingsStrings = {
  allSettings: string;
  expired: (providerName: string) => string;
  disconnected: (providerName: string) => string;
  toolsOnly: (providerName: string) => string;
};

export const defaultAiQuickSettingsStrings: AiQuickSettingsStrings = {
  allSettings: 'All AI settings',
  expired: provider => `Your ${provider} sign-in expired. Your model and effort choices stay saved for after you reconnect.`,
  disconnected: provider => `${provider} isn’t connected. Connect it in AI settings to choose a model.`,
  toolsOnly: provider => `${provider} is available for tools, but model selection isn’t available here.`,
};

export type AiQuickSettingsPanelProps = {
  providerName: string;
  connection: AiQuickSettingsConnection;
  onOpenSettings: () => void;
  reconnectAction?: ReactNode;
  children?: ReactNode;
  strings?: Partial<AiQuickSettingsStrings>;
  className?: string;
};

export function AiQuickSettingsPanel(props: AiQuickSettingsPanelProps) {
  const strings = { ...defaultAiQuickSettingsStrings, ...props.strings };
  return <section className={`byos byos-quick-settings${props.className ? ` ${props.className}` : ''}`}>
    <header className="byos-quick-settings-header">
      <strong className="byos-quick-settings-provider">{props.providerName}</strong>
      <button type="button" className="byos-quick-settings-all" onClick={props.onOpenSettings}>{strings.allSettings}</button>
    </header>
    {props.connection === 'expired' && <div className="byos-quick-settings-warning" role="status">
      <p>{strings.expired(props.providerName)}</p>{props.reconnectAction && <div className="byos-quick-settings-reconnect">{props.reconnectAction}</div>}
    </div>}
    {props.connection === 'disconnected' && <p className="byos-quick-settings-note">{strings.disconnected(props.providerName)}</p>}
    {props.connection === 'tools-only' && <p className="byos-quick-settings-note">{strings.toolsOnly(props.providerName)}</p>}
    {(props.connection === 'connected' || props.connection === 'expired') && props.children != null && <div className="byos-quick-settings-content">{props.children}</div>}
  </section>;
}
