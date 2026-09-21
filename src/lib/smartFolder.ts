import type { Feed, Folder, SmartRules } from "../services/types";

export function parseRules(folder: Folder): SmartRules | null {
  if (!folder.is_smart || !folder.rules_json) return null;
  try {
    const parsed: unknown = JSON.parse(folder.rules_json);
    if (!parsed || typeof parsed !== "object") return null;
    const data = parsed as Record<string, unknown>;
    const mode = data.mode === undefined ? "any" : data.mode;
    if ((mode !== "any" && mode !== "all") || !Array.isArray(data.rules)) return null;
    const rules: SmartRules["rules"] = [];
    for (const item of data.rules) {
      if (!item || typeof item !== "object") return null;
      const rule = item as Record<string, unknown>;
      if (!["regex_title", "regex_url", "opml_category"].includes(String(rule.type))) return null;
      const key = rule.type === "opml_category" ? "value" : "pattern";
      const value = rule[key] === undefined ? rule.pattern_or_value : rule[key];
      if (typeof value !== "string") return null;
      if (rule[key] === undefined && rule.case_sensitive !== undefined && typeof rule.case_sensitive !== "boolean") return null;
      if (rule.type === "opml_category") rules.push({ type: rule.type, value });
      else rules.push({
        type: rule.type as "regex_title" | "regex_url",
        pattern: rule[key] === undefined && rule.case_sensitive !== true ? `(?i:${value})` : value,
      });
    }
    return { mode, rules };
  } catch {
    return null;
  }
}

/** Use backend membership so preview, counts, sidebar and articles agree. */
export function feedsForFolder(folder: Folder, feeds: Feed[]): Feed[] {
  if (folder.is_smart) {
    const matching = new Set(folder.matching_feed_ids ?? []);
    return feeds.filter((feed) => matching.has(feed.id));
  }
  return feeds.filter((feed) => feed.folder_id === folder.id);
}
