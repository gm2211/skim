export type PaletteStrings = {
  dialogLabel: string;
  inputLabel: string;
  placeholder: string;
  /** Placeholder when there is no Ask binding. */
  placeholderNoAsk: string;
  followUpPlaceholder: string;
  listLabel: string;
  noMatches: string;
  pending: string;
  close: string;
  hintNavigate: string;
  hintRun: string;
  hintAsk: string;
  hintAskFull: string;
  hintBack: string;
  hintToggle: string;
  openFull: string;
  trigger: string;
};

export const defaultPaletteStrings: PaletteStrings = {
  dialogLabel: 'Command palette',
  inputLabel: 'Search commands',
  placeholder: 'Type a command, or ask anything…',
  placeholderNoAsk: 'Search commands…',
  followUpPlaceholder: 'Ask a follow-up…',
  listLabel: 'Commands',
  noMatches: 'No matching commands',
  pending: 'Working on it…',
  close: 'Close',
  hintNavigate: 'navigate',
  hintRun: 'run',
  hintAsk: 'ask',
  hintAskFull: 'ask in full chat',
  hintBack: 'commands',
  hintToggle: 'toggle',
  openFull: 'Open full chat',
  trigger: 'Commands',
};
