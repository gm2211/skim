import Foundation

/// Mutation responses own different fields and may resume out of database order.
public enum TodayEditionMerge {
    public static func ledes(current: TodayEditionSnapshot?, response: TodayEditionSnapshot) -> TodayEditionSnapshot {
        guard var current else { return response }
        guard current.id == response.id else { return current }
        for incoming in response.items {
            guard let lede = nonempty(incoming.snapshot.lede),
                  let index = current.items.firstIndex(where: { $0.id == incoming.id }),
                  nonempty(current.items[index].snapshot.lede) == nil else { continue }
            current.items[index].snapshot.lede = lede
            current.items[index].snapshot.ledeSourceArticleID = incoming.snapshot.ledeSourceArticleID
            current.items[index].snapshot.ledeSourceEvidenceHash = incoming.snapshot.ledeSourceEvidenceHash
        }
        return current
    }

    public static func consumption(current: TodayEditionSnapshot?, response: TodayEditionSnapshot) -> TodayEditionSnapshot {
        guard let current else { return response }
        guard current.id == response.id else { return current }
        var result = response
        for existing in current.items {
            guard let lede = nonempty(existing.snapshot.lede),
                  let index = result.items.firstIndex(where: { $0.id == existing.id }) else { continue }
            result.items[index].snapshot.lede = lede
            result.items[index].snapshot.ledeSourceArticleID = existing.snapshot.ledeSourceArticleID
            result.items[index].snapshot.ledeSourceEvidenceHash = existing.snapshot.ledeSourceEvidenceHash
        }
        return result
    }

    private static func nonempty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
