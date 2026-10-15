// The palette's matching, question detection and shortcut labels come from BYOS
// (@byos/commands), shared with the other BYOS apps. This module keeps Skim's names.
import { rankCommands, type Command } from "@byos/commands";

export { askFirst, formatShortcutKey, isMacPlatform, isQuestionLike, scoreCommand, scoreText } from "@byos/commands";

export type PaletteCommand = Command;

/** Matching commands, best first; keeps the given list for an empty query. */
export function filterCommands(commands: PaletteCommand[], query: string): PaletteCommand[] {
  return query.trim() ? rankCommands(commands, query) : commands;
}
