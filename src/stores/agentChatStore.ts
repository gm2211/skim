import { create } from "zustand";
import type { AgentContext } from "../services/commands";
import type { AgentMessage } from "../lib/agentContext";
import { runAppCommand } from "../lib/appCommands";

/** A conversation handed to the full Ask Skim chat to continue there. */
export interface AgentChatSeed {
  context: AgentContext;
  /** Title of the article open in the reader, for naming the context. */
  articleTitle?: string | null;
  messages?: AgentMessage[];
  /** Text for the input. */
  prompt?: string;
  /** Send `prompt` as soon as the chat opens. */
  autoSend?: boolean;
}

interface AgentChatState {
  seed: AgentChatSeed | null;
  setSeed: (seed: AgentChatSeed | null) => void;
}

export const useAgentChatStore = create<AgentChatState>((set) => ({
  seed: null,
  setSeed: (seed) => set({ seed }),
}));

/**
 * Open the full Ask Skim chat on an agent conversation: the palette's
 * "Open full chat", or "Ask about this page / story" with just a context.
 */
export function openAgentChat(seed: AgentChatSeed) {
  useAgentChatStore.getState().setSeed(seed);
  runAppCommand("ask-skim");
}
