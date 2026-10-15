import type { Command, SyncCommandSource } from './command.js';

/** Public connection metadata only. Never pass a token, key, or raw provider error here. */
export type AiCommandStatus = {
  /** Provider display name when one is chosen, e.g. "ChatGPT". */
  providerName?: string;
  /** Model display name, when one is chosen. */
  modelName?: string;
  connected: boolean;
  /** Signed in before but the session needs renewing. */
  expired?: boolean;
};

export type AiCommandStrings = {
  group: string;
  settings: string;
  signIn: (provider?: string) => string;
  reconnect: (provider?: string) => string;
  switchModel: string;
  switchProvider: string;
  signOut: (provider?: string) => string;
  connectedDetail: (status: AiCommandStatus) => string;
  disconnectedDetail: string;
};

export const defaultAiCommandStrings: AiCommandStrings = {
  group: 'AI',
  settings: 'AI settings',
  signIn: provider => (provider ? `Connect ${provider}` : 'Connect AI'),
  reconnect: provider => (provider ? `Reconnect ${provider}` : 'Reconnect AI'),
  switchModel: 'Change AI model',
  switchProvider: 'Change AI service',
  signOut: provider => (provider ? `Disconnect ${provider}` : 'Disconnect AI'),
  connectedDetail: status => [status.providerName, status.modelName].filter(Boolean).join(' · '),
  disconnectedDetail: 'Not connected',
};

export type AiCommandsOptions = {
  /** Read on every keystroke, so it always reflects the current connection. */
  status: () => AiCommandStatus;
  /** Open the application's AI settings, optionally on a section it understands ("model", "account"). */
  openSettings: (section?: string) => void;
  /** Start sign-in. Omit to send people to settings instead. */
  signIn?: () => void;
  signOut?: () => void;
  /** Open the model picker. Omit to open settings on "model". */
  switchModel?: () => void;
  switchProvider?: () => void;
  strings?: Partial<AiCommandStrings>;
  id?: string;
  order?: number;
};

/** The same AI commands in every BYOS application: settings, connect or reconnect, model, service, disconnect. */
export function byosAiCommands(options: AiCommandsOptions): SyncCommandSource {
  const text = { ...defaultAiCommandStrings, ...options.strings };
  return {
    id: options.id ?? 'byos.ai',
    order: options.order,
    commands: () => {
      const status = options.status();
      const group = text.group;
      const detail = status.connected ? text.connectedDetail(status) || undefined : text.disconnectedDetail;
      const rows: Command[] = [{
        id: 'byos.ai.settings', group, title: text.settings, icon: 'sparkle', detail,
        keywords: ['preferences', 'provider', 'model', 'api key', 'subscription', 'account'],
        run: () => options.openSettings(),
      }];
      if (!status.connected || status.expired) {
        const title = status.expired ? text.reconnect(status.providerName) : text.signIn(status.providerName);
        rows.push({
          id: 'byos.ai.connect', group, title, icon: 'plug', keywords: ['sign in', 'log in', 'login', 'connect', 'subscription'],
          run: () => (options.signIn ? options.signIn() : options.openSettings('account')),
        });
      }
      if (status.connected) {
        rows.push({
          id: 'byos.ai.model', group, title: text.switchModel, icon: 'sliders', detail: status.modelName,
          keywords: ['switch', 'model', 'effort', 'reasoning'],
          run: () => (options.switchModel ? options.switchModel() : options.openSettings('model')),
        });
      }
      if (options.switchProvider) {
        rows.push({ id: 'byos.ai.provider', group, title: text.switchProvider, icon: 'swap', keywords: ['switch', 'provider'], run: options.switchProvider });
      }
      if (status.connected && options.signOut) {
        rows.push({ id: 'byos.ai.signOut', group, title: text.signOut(status.providerName), icon: 'logout', keywords: ['sign out', 'log out', 'logout', 'forget'], searchOnly: true, run: options.signOut });
      }
      return rows;
    },
  };
}
