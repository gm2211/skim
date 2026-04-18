import type { Feed, Folder, SmartRules, SmartRule } from "../services/types";

export function parseRules(folder: Folder): SmartRules | null {
  if (!folder.is_smart || !folder.rules_json) return null;
  try {
    return JSON.parse(folder.rules_json) as SmartRules;
  } catch {
    return null;
  }
}

function ruleMatches(rule: SmartRule, feed: Feed): boolean {
  switch (rule.type) {
    case "regex_title":
      try {
        return new RegExp(rule.pattern).test(feed.title);
      } catch {
        return false;
      }
    case "regex_url":
      try {
        return new RegExp(rule.pattern).test(feed.url);
      } catch {
        return false;
      }
    case "opml_category":
      return (feed.opml_category ?? "").toLowerCase() === rule.value.toLowerCase();
  }
}

export function matchFeedsToSmartFolder(rules: SmartRules, feeds: Feed[]): Feed[] {
  if (rules.rules.length === 0) return [];
  return feeds.filter((f) =>
    rules.mode === "all"
      ? rules.rules.every((r) => ruleMatches(r, f))
      : rules.rules.some((r) => ruleMatches(r, f)),
  );
}

export function feedsForFolder(folder: Folder, feeds: Feed[]): Feed[] {
  if (folder.is_smart) {
    const rules = parseRules(folder);
    if (!rules) return [];
    return matchFeedsToSmartFolder(rules, feeds);
  }
  return feeds.filter((f) => f.folder_id === folder.id);
}
