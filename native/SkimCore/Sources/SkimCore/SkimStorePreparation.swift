import Foundation
import SQLite3
import SkimStoryPolicy

private func prepText(_ row: OpaquePointer, _ column: Int32) -> String { sqlite3_column_text(row, column).map { String(cString: $0) } ?? "" }
struct PreparationTask {
    var key: String
    var kind: String
    var request: TodayPreparationRequest
    var members: [String]
    var result: [Int32]?
    var failed: Bool
}
struct PreparationTemplate {
    var key: String
    var reports: [String: TodayPreparationPolicy.Report]
    var assessments: [PreparationTask]
    var proposals: [PreparationTask]
}
private struct PreparationContext {
    var scope: String
    var candidates: [TodayEditionCandidate]
    var assessments: [PreparationTask]
    var proposals: [PreparationTask]
    var pairs: [PreparationTask]
    var status: TodayPreparationStatus
}

extension SQLiteDatabase {
    func migratePreparation() throws {
        try execute("CREATE TABLE IF NOT EXISTS today_preparation_scopes (scope_key TEXT PRIMARY KEY, inference TEXT NOT NULL, active_edition_id TEXT, published_manifest TEXT)")
        try execute("CREATE TABLE IF NOT EXISTS today_preparation_slots (scope_key TEXT NOT NULL, story_id TEXT NOT NULL, slot INTEGER NOT NULL, PRIMARY KEY(scope_key,story_id), UNIQUE(scope_key,slot))")
        try execute("CREATE TABLE IF NOT EXISTS today_preparation_editions (edition_id TEXT PRIMARY KEY, manifest TEXT NOT NULL, coverage TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS today_preparation_tasks (task_key TEXT PRIMARY KEY, kind TEXT NOT NULL, status TEXT NOT NULL, result TEXT, updated_at REAL NOT NULL)")
    }
    func preparationScope(startsAt: Date, endsAt: Date, storyLimit: Int) -> String {
        TodayEditionBuilder.stableID(startsAt: startsAt, endsAt: endsAt, storyLimit: storyLimit)
    }
    func preparationActiveEdition(startsAt: Date, endsAt: Date, storyLimit: Int) throws -> String? {
        try query("SELECT active_edition_id FROM today_preparation_scopes WHERE scope_key=?", [.text(preparationScope(startsAt: startsAt, endsAt: endsAt, storyLimit: storyLimit))]) {
            sqlite3_column_type($0, 0) == SQLITE_NULL ? nil : prepText($0, 0)
        }.first ?? nil
    }
    fileprivate func preparationConsumed(storyID: String, startsAt: Date, endsAt: Date) throws -> Bool {
        try query("""
                        SELECT 1 FROM edition_item_story_revisions r
                        JOIN edition_items i ON i.edition_id=r.edition_id AND i.story_id=r.item_story_id
                        JOIN editions e ON e.id=i.edition_id
                        WHERE r.member_story_id=? AND e.starts_at=? AND e.ends_at=? AND i.is_consumed=1
                        AND NOT EXISTS (SELECT 1 FROM story_revisions newer WHERE newer.story_id=r.member_story_id
                            AND newer.revision_number>r.revision_number AND newer.is_material_change=1
                            AND newer.created_at>=? AND newer.created_at<?) LIMIT 1
                        """, [.text(storyID), .date(startsAt), .date(endsAt), .date(startsAt), .date(endsAt)]) { _ in true }.first ?? false
    }
    fileprivate func preparationContext(startsAt: Date, endsAt: Date, storyLimit: Int, inference: String, preferences: TodayRankingPreferences) throws -> PreparationContext {
        guard endsAt > startsAt, TodayEditionBuilder.supportedStoryLimits.contains(storyLimit) else { throw SkimCoreError.database("Invalid preparation scope") }
        let scope = preparationScope(startsAt: startsAt, endsAt: endsAt, storyLimit: storyLimit)
        try execute("INSERT INTO today_preparation_scopes(scope_key,inference) VALUES(?,?) ON CONFLICT(scope_key) DO UPDATE SET inference=excluded.inference", [.text(scope), .text(inference)])
        try execute("DELETE FROM today_preparation_tasks WHERE updated_at<?", [.date(Date().addingTimeInterval(-7 * 86400))])
        let candidates = try todayEditionCandidates(startsAt: startsAt, endsAt: endsAt, preferences: preferences).filter {
            try !preparationConsumed(storyID: $0.ranking.story.id, startsAt: startsAt, endsAt: endsAt)
        }.sorted { $0.ranking.story.id < $1.ranking.story.id }
        var slots = Dictionary(uniqueKeysWithValues: try query("SELECT story_id,slot FROM today_preparation_slots WHERE scope_key=?", [.text(scope)]) { (prepText($0, 0), Int(sqlite3_column_int64($0, 1))) })
        var next = (slots.values.max() ?? -1) + 1
        for candidate in candidates where slots[candidate.ranking.story.id] == nil {
            let id = candidate.ranking.story.id
            try execute("INSERT INTO today_preparation_slots(scope_key,story_id,slot) VALUES(?,?,?)", [.text(scope), .text(id), .int(next)])
            slots[id] = next; next += 1
        }
        let cached = Dictionary(uniqueKeysWithValues: try query("SELECT task_key,status,result FROM today_preparation_tasks") { row in
            (prepText(row, 0), (prepText(row, 1), try? JSONDecoder().decode([Int32].self, from: Data(prepText(row, 2).utf8))))
        })
        let sourceManifest = try candidates.map { candidate in
            try [TodayPreparationPolicy.json(candidate.ranking.story), TodayPreparationPolicy.json(candidate.revision)] + candidate.sourceArticles.flatMap { source in
                var article = source.article
                article.isRead = false
                article.isStarred = false
                return [try TodayPreparationPolicy.json(article), try TodayPreparationPolicy.json(source.membership)]
            }
        }.flatMap { $0 }
        let templateKey = TodayPreparationPolicy.hash(([scope, inference] + sourceManifest).joined(separator: "\n"))
        let previous = preparationTemplates[scope]
        let formatter = TodayPreparationPolicy.dateFormatter()
        let reports = previous?.key == templateKey ? previous!.reports : Dictionary(uniqueKeysWithValues: candidates.map { ($0.ranking.story.id, TodayPreparationPolicy.report($0, formatter: formatter)) })
        func validCached(_ result: [Int32]?, kind: String, count: Int) -> [Int32]? {
            guard let result else { return nil }
            let response: String
            if kind == "proposal" {
                guard result.count == count, let maximum = result.max(), maximum >= 0,
                      maximum < count, Set(result) == Set(0...maximum) else { return nil }
                let groups = (0...maximum).map { group in result.indices.filter { result[$0] == group } }
                guard let value = try? TodayPreparationPolicy.json(["groups": groups]) else { return nil }
                response = value
            } else if kind == "assessment" {
                guard result.count == 1 else { return nil }
                response = "{\"importance\":\(result[0])}"
            } else {
                guard result.count == 1, (0...2).contains(result[0]) else { return nil }
                response = "{\"relation\":\"\(["different_event", "same_event", "uncertain"][Int(result[0])])\"}"
            }
            return (try? TodayPreparationPolicy.validate(response, kind: kind, count: count)) == result ? result : nil
        }
        func task(_ kind: String, _ request: TodayPreparationRequest, _ members: [String]) -> PreparationTask {
            let key = TodayPreparationPolicy.taskKey(request, inference: inference)
            return PreparationTask(key: key, kind: kind, request: request, members: members,
                result: cached[key]?.0 == "complete" ? validCached(cached[key]?.1, kind: kind, count: members.count) : nil, failed: cached[key]?.0 == "failed")
        }
        var assessments: [PreparationTask]
        var proposals: [PreparationTask]
        if let previous, previous.key == templateKey {
            assessments = previous.assessments
            proposals = previous.proposals
        } else {
        assessments = try candidates.map { candidate in
            let id = candidate.ranking.story.id
            return task("assessment", try TodayPreparationPolicy.assessment(reports[id]!), [id])
        }
        proposals = []
        let windows = skim_preparation_window_count(next)
        guard windows != UInt64.max else { throw SkimCoreError.database("Preparation inventory too large") }
        for ordinal in 0..<windows {
            var first = 0, firstCount = 0, second = 0, secondCount = 0
            guard skim_preparation_window_at(next, ordinal, &first, &firstCount, &second, &secondCount) != 0 else { throw SkimCoreError.database("Invalid preparation window") }
            let members = candidates.map { $0.ranking.story.id }.filter {
                let slot = slots[$0]!
                return (first..<(first + firstCount)).contains(slot) || (secondCount > 0 && (second..<(second + secondCount)).contains(slot))
            }.sorted { slots[$0]! < slots[$1]! }
            if members.isEmpty { continue }
            proposals.append(task("proposal", try TodayPreparationPolicy.proposal(members.map { reports[$0]! }), members))
        }
        preparationTemplates[scope] = PreparationTemplate(key: templateKey, reports: reports, assessments: assessments, proposals: proposals)
        }
        func refresh(_ value: PreparationTask) -> PreparationTask {
            var value = value
            value.result = cached[value.key]?.0 == "complete" ? validCached(cached[value.key]?.1, kind: value.kind, count: value.members.count) : nil
            value.failed = cached[value.key]?.0 == "failed"
            return value
        }
        assessments = assessments.map(refresh)
        proposals = proposals.map(refresh)
        var proposed = Set<String>()
        var pairs: [PreparationTask] = []
        for window in proposals {
            guard let labels = window.result, labels.count == window.members.count else { continue }
            for left in window.members.indices {
                for right in window.members.indices where right > left && labels[left] == labels[right] {
                    let members = [window.members[left], window.members[right]].sorted()
                    let request = try TodayPreparationPolicy.pair(reports[members[0]]!, reports[members[1]]!)
                    let pair = task("pair", request, members)
                    if proposed.insert(try TodayPreparationPolicy.json(members)).inserted { pairs.append(pair) }
                }
            }
        }
        pairs.sort { $0.members.lexicographicallyPrecedes($1.members) }
        let all = assessments + proposals + pairs
        let failures = all.filter(\.failed).count
        let pending = all.contains { $0.result == nil && !$0.failed }
        let consumed = try query("SELECT DISTINCT r.member_story_id,r.revision_number FROM edition_item_story_revisions r JOIN edition_items i ON i.edition_id=r.edition_id AND i.story_id=r.item_story_id JOIN editions e ON e.id=i.edition_id WHERE e.starts_at=? AND e.ends_at=? AND i.is_consumed=1 ORDER BY r.member_story_id,r.revision_number", [.date(startsAt), .date(endsAt)]) { "\(prepText($0, 0)):\(sqlite3_column_int64($0, 1))" }

        let outcomes = try all.map { "\($0.key):\($0.failed):\(try TodayPreparationPolicy.json($0.result))" }
        let manifest = TodayPreparationPolicy.hash(([scope, inference] + sourceManifest + outcomes + consumed).joined(separator: "\n"))
        let pointer = try query("SELECT active_edition_id,published_manifest FROM today_preparation_scopes WHERE scope_key=?", [.text(scope)]) { (prepText($0, 0), prepText($0, 1)) }.first!
        let state = inference == "disabled" ? "disabled" : candidates.isEmpty ? "empty" : pending ? "preparing" : failures > 0 ? "failed" : "ready"
        let status = try TodayPreparationStatus(scopeKey: scope, eligibleCount: candidates.count,
            assessedCount: assessments.filter { $0.result != nil }.count, assessmentFailedCount: assessments.filter(\.failed).count,
            proposalWindowCount: proposals.count, proposalCompletedCount: proposals.filter { $0.result != nil }.count, proposalFailedCount: proposals.filter(\.failed).count,
            proposedPairCount: pairs.count, verifiedPairCount: pairs.filter { $0.result != nil }.count, verificationFailedCount: pairs.filter(\.failed).count,
            state: state, manifest: manifest, canPublish: state == "ready" && pointer.1 != manifest && candidates.contains { !(try preparationConsumed(storyID: $0.ranking.story.id, startsAt: startsAt, endsAt: endsAt)) },
            activeEditionID: pointer.0.isEmpty ? nil : pointer.0)
        return PreparationContext(scope: scope, candidates: candidates, assessments: assessments, proposals: proposals, pairs: pairs, status: status)
    }
}

extension SkimStore {
    public func todayPreparationStatus(startsAt: Date, endsAt: Date, storyLimit: Int, inference: String, preferences: TodayRankingPreferences = .init()) throws -> TodayPreparationStatus {
        try db.preparationContext(startsAt: startsAt, endsAt: endsAt, storyLimit: storyLimit, inference: inference, preferences: preferences).status
    }
    public func cancelTodayPreparation(scope: String, requestID: UUID) {
        if preparationRequests[scope] == requestID { preparationRequests[scope] = nil }
    }
    public func prepareTodaySlice(startsAt: Date, endsAt: Date, storyLimit: Int, inference: String, requestID: UUID,
        retryFailed: Bool = false, preferences: TodayRankingPreferences = .init(), request: @escaping TodayPreparationInference) async throws -> TodayPreparationStatus {
        var context = try db.preparationContext(startsAt: startsAt, endsAt: endsAt, storyLimit: storyLimit, inference: inference, preferences: preferences)
        preparationRequests[context.scope] = requestID
        if retryFailed {
            for task in context.assessments + context.proposals + context.pairs where task.failed {
                try db.execute("DELETE FROM today_preparation_tasks WHERE task_key=? AND status='failed'", [.text(task.key)])
            }
            context = try db.preparationContext(startsAt: startsAt, endsAt: endsAt, storyLimit: storyLimit, inference: inference, preferences: preferences)
        }
        let deadline = Date().addingTimeInterval(30)
        for _ in 0..<1 {
            try Task.checkCancellation()
            guard context.status.state == "preparing", Date() < deadline,
                  let task = (context.assessments + context.proposals + context.pairs).first(where: { $0.result == nil && !$0.failed }) else { break }
            let result: [Int32]?
            do {
                let raw = try await PreparationDeadline.perform(task.request, timeout: max(0.001, deadline.timeIntervalSinceNow), request: request)
                result = try TodayPreparationPolicy.validate(raw, kind: task.kind, count: task.members.count)
            } catch is CancellationError { throw CancellationError() }
            catch { result = nil }
            try Task.checkCancellation()
            guard preparationRequests[context.scope] == requestID else { throw CancellationError() }
            let activeInference = try db.query("SELECT inference FROM today_preparation_scopes WHERE scope_key=?", [.text(context.scope)]) { prepText($0, 0) }.first
            guard activeInference == inference else { throw CancellationError() }
            let fresh = try db.preparationContext(startsAt: startsAt, endsAt: endsAt, storyLimit: storyLimit, inference: inference, preferences: preferences)
            guard (fresh.assessments + fresh.proposals + fresh.pairs).contains(where: { $0.key == task.key }) else { context = fresh; continue }
            try db.execute("INSERT INTO today_preparation_tasks(task_key,kind,status,result,updated_at) VALUES(?,?,?,?,?) ON CONFLICT(task_key) DO UPDATE SET status=excluded.status,result=excluded.result,updated_at=excluded.updated_at", [.text(task.key), .text(task.kind), .text(result == nil ? "failed" : "complete"), .text(try TodayPreparationPolicy.json(result)), .date(Date())])
            context = try db.preparationContext(startsAt: startsAt, endsAt: endsAt, storyLimit: storyLimit, inference: inference, preferences: preferences)
        }
        return context.status
    }
}

extension SkimStore {
    public func publishPreparedTodayEdition(startsAt: Date, endsAt: Date, storyLimit: Int, generatedAt: Date = Date(),
        inference: String, manifest: String, preferences: TodayRankingPreferences = .init()) throws -> TodayEditionSnapshot {
        try Task.checkCancellation()
        guard generatedAt >= startsAt && generatedAt < endsAt else { throw SkimCoreError.database("Today window changed") }
        let scope = db.preparationScope(startsAt: startsAt, endsAt: endsAt, storyLimit: storyLimit)
        let currentInference = try db.query("SELECT inference FROM today_preparation_scopes WHERE scope_key=?", [.text(scope)]) { prepText($0, 0) }.first
        guard currentInference == inference else { throw SkimCoreError.database("Preparation settings changed") }
        var published: String?
        try db.transaction {
            let context = try db.preparationContext(startsAt: startsAt, endsAt: endsAt, storyLimit: storyLimit, inference: inference, preferences: preferences)
            guard context.status.manifest == manifest, context.status.state == "ready" else { throw SkimCoreError.database("Preparation changed. Refresh Today and try again.") }
            let editionID = "\(context.scope)-prepared-\(manifest)"
            if try db.edition(id: editionID) != nil {
                published = editionID
            } else {
                let candidates = try context.candidates.filter { candidate in
                    let consumed = try db.preparationConsumed(storyID: candidate.ranking.story.id, startsAt: startsAt, endsAt: endsAt)
                    return !consumed
                }
                guard !candidates.isEmpty else { throw SkimCoreError.database("You have already read the prepared stories.") }
                let ids = candidates.map { $0.ranking.story.id }
                let indices = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
                let edges = context.pairs.filter { $0.result == [1] }.compactMap { task -> [Int]? in
                    guard let a = indices[task.members[0]], let b = indices[task.members[1]] else { return nil }
                    return [min(a,b), max(a,b)]
                }.sorted { $0.lexicographicallyPrecedes($1) }
                var labels = [Int32](repeating: -1, count: candidates.count)
                let left = edges.map { $0[0] }, right = edges.map { $0[1] }
                let count = left.withUnsafeBufferPointer { l in right.withUnsafeBufferPointer { r in labels.withUnsafeMutableBufferPointer { out in
                    skim_preparation_partition(candidates.count, l.baseAddress, r.baseAddress, edges.count, out.baseAddress, out.count)
                } } }
                guard count > 0 else { throw SkimCoreError.database("Invalid prepared groups") }
                let assessment = Dictionary(uniqueKeysWithValues: context.assessments.map { ($0.members[0], $0.result?.first ?? -1) })
                let ratings = ids.map { assessment[$0] ?? -1 }
                let inputs = TodaySemanticPolicy.inputs(candidates, at: generatedAt)
                var grouped: [TodayEditionCandidate] = []
                for label in 0..<count {
                    let members = candidates.indices.filter { labels[$0] == label }
                    let anchor = members.sorted { inputs[$0].baseScore == inputs[$1].baseScore ? ids[$0] < ids[$1] : inputs[$0].baseScore > inputs[$1].baseScore }[0]
                    var candidate = candidates[anchor]
                    var seen = Set<String>()
                    candidate.sourceArticles = members.flatMap { candidates[$0].sourceArticles }.filter { seen.insert($0.article.id).inserted }
                    candidate.memberRevisions = members.map { TodayStoryRevisionReference(storyID: ids[$0], revisionNumber: candidates[$0].revision.revisionNumber) }
                    candidate.ranking.distinctFeedCount = Set(candidate.sourceArticles.filter { $0.membership.membershipType != .duplicate }.map { $0.article.feedID }).count
                    candidate.ranking.articleCount = candidate.sourceArticles.count
                    let importance = ratings.withUnsafeBufferPointer { values in labels.withUnsafeBufferPointer { groups in
                        skim_preparation_group_importance(values.baseAddress, groups.baseAddress, values.count, label)
                    } }
                    guard importance >= 0 else { throw SkimCoreError.database("Invalid prepared importance") }
                    candidate.semanticScore = skim_semantic_score(inputs[anchor].baseScore, Double(importance), 1)
                    candidate.semanticReason = "From your feeds"
                    grouped.append(candidate)
                }
                let generated = TodayEditionBuilder.buildItems(editionID: editionID, candidates: grouped, storyLimit: storyLimit, generatedAt: generatedAt, semantic: true)
                let feeds = Set(generated.flatMap(\.sourceArticles).filter { $0.membershipType != .duplicate }.map(\.feedID))
                try db.insertEdition(Edition(id: editionID, title: "Today", scope: "today", storyLimit: storyLimit, status: .ready,
                    startsAt: startsAt, endsAt: endsAt, generatedAt: generatedAt, completedAt: nil, totalSourceCount: feeds.count))
                for item in generated {
                    try db.insertEditionItem(item.item)
                    for member in item.memberRevisions {
                        try db.execute("INSERT OR IGNORE INTO edition_item_story_revisions(edition_id,item_story_id,member_story_id,revision_number) VALUES(?,?,?,?)", [.text(editionID), .text(item.item.storyID), .text(member.storyID), .int(member.revisionNumber)])
                    }
                    for source in item.sourceArticles { try db.insertEditionItemSource(editionID: editionID, storyID: item.item.storyID, source: source) }
                }
                try db.execute("INSERT INTO today_preparation_editions(edition_id,manifest,coverage) VALUES(?,?,?)", [.text(editionID), .text(manifest), .text(try TodayPreparationPolicy.json(context.status))])
                published = editionID
            }
            try Task.checkCancellation()
            try db.execute("UPDATE today_preparation_scopes SET active_edition_id=?,published_manifest=? WHERE scope_key=?", [.text(editionID), .text(manifest), .text(context.scope)])
        }
        return try db.todayEditionSnapshot(id: published!)
    }
}

private final class PreparationDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, any Error>?
    private var result: Result<String, any Error>?
    private var tasks: [Task<Void, Never>] = []
    private func install(_ value: CheckedContinuation<String, any Error>) {
        lock.lock()
        if let result { lock.unlock(); value.resume(with: result) }
        else { continuation = value; lock.unlock() }
    }
    private func retain(_ task: Task<Void, Never>) {
        lock.lock(); let done = result != nil
        if !done { tasks.append(task) }
        lock.unlock(); if done { task.cancel() }
    }
    private func finish(_ value: Result<String, any Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let callback = continuation; continuation = nil
        let pending = tasks; tasks = []
        lock.unlock()
        pending.forEach { $0.cancel() }; callback?.resume(with: value)
    }
    static func perform(_ input: TodayPreparationRequest, timeout: Double, request: @escaping TodayPreparationInference) async throws -> String {
        let gate = PreparationDeadline()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                gate.retain(Task {
                    do { gate.finish(.success(try await request(input))) }
                    catch { gate.finish(.failure(error)) }
                })
                gate.retain(Task {
                    do { try await Task.sleep(for: .seconds(timeout)) }
                    catch { return }
                    gate.finish(.failure(SkimCoreError.database("Preparation slice timed out")))
                })
            }
        } onCancel: { gate.finish(.failure(CancellationError())) }
    }
}
