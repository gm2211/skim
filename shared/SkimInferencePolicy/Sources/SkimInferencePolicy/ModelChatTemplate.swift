import Foundation

/// Structural cache readiness for the swift-transformers 1.0 tokenizer loader.
/// This checks template availability and selection, not Jinja syntax/execution.
public enum ModelChatTemplate {
    public static func isUsable(in directory: URL) -> Bool {
        let fileManager = FileManager.default
        let configURL = directory.appendingPathComponent("tokenizer_config.json")
        var config: [String: Any] = [:]
        if fileManager.fileExists(atPath: configURL.path) {
            // Hub loads this before considering an external template; malformed
            // existing config cannot be repaired by merely adding a .jinja file.
            guard let parsed = object(at: configURL) else { return false }
            config = parsed
        }

        let jinjaURL = directory.appendingPathComponent("chat_template.jinja")
        if fileManager.fileExists(atPath: jinjaURL.path) {
            if let template = regularText(at: jinjaURL) {
                // A readable but empty external file overrides embedded content.
                return nonempty(template)
            }
            // The loader's try? read leaves embedded configuration intact.
        } else if let external = object(at: directory.appendingPathComponent("chat_template.json")),
                  let template = external["chat_template"] as? String {
            return nonempty(template)
        }
        if let template = config["chat_template"] as? String {
            return nonempty(template)
        }
        guard let entries = config["chat_template"] as? [Any] else { return false }
        var templates: [String: String] = [:]
        for value in entries {
            guard let entry = value as? [String: Any],
                  let name = entry["name"] as? String,
                  let template = entry["template"] as? String else { continue }
            // The loader builds Dictionary(uniqueKeysWithValues:); duplicates
            // would trap, even if the duplicated name is not the default.
            guard templates[name] == nil else { return false }
            templates[name] = template
        }
        return templates["default"].map(nonempty) ?? false
    }

    private static func nonempty(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func regularText(at url: URL) -> String? {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func object(at url: URL) -> [String: Any]? {
        guard let text = regularText(at: url),
              let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return value
    }
}
