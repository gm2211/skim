import Foundation
import Testing
@testable import SkimCore

private func redditNode(_ id: String, _ body: String, _ replies: [[String: Any]] = []) -> [String: Any] {
    let repliesValue: Any = replies.isEmpty ? "" : ["kind": "Listing", "data": ["children": replies]]
    return ["kind": "t1", "data": ["id": id, "author": "u_\(id)", "score": 5, "body": body, "replies": repliesValue]]
}

@Test func flattensRedditReplyTreesInThreadOrder() {
    let root: [[String: Any]] = [
        ["kind": "Listing", "data": ["children": [["kind": "t3", "data": ["score": 10]]]]],
        ["kind": "Listing", "data": ["children": [
            redditNode("a", "top", [
                redditNode("a1", "reply", [redditNode("a11", "deeper")]),
                redditNode("gone", "[removed]", [redditNode("orphan", "lost")])
            ]),
            ["kind": "more", "data": ["count": 40]],
            redditNode("b", "second")
        ]]]
    ]

    let comments = AggregatorService.redditComments(fromThread: root, limit: 10)
    #expect(comments.map(\.id) == ["a", "a1", "a11", "b"])
    #expect(comments.map(\.depth) == [0, 1, 2, 0])
    #expect(AggregatorService.redditComments(fromThread: root, limit: 1).count == 3)
}

@Test func readsRedditCommentsFromThreadFeed() {
    let feed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom"><title>post</title>
    <entry><author><name>/u/op</name></author><content type="html">&lt;div class="md"&gt;&lt;p&gt;the post&lt;/p&gt;&lt;/div&gt;</content><id>t3_abc</id><title>post</title></entry>
    <entry><author><name>/u/alice</name></author><content type="html">&lt;div class="md"&gt;&lt;p&gt;Tom &amp;amp; Jerry&lt;/p&gt;&lt;p&gt;Second&lt;/p&gt;&lt;/div&gt;</content><id>t1_def</id><title>/u/alice on post</title></entry>
    </feed>
    """

    let comments = AggregatorService.redditFeedComments(from: Data(feed.utf8), limit: 10)
    #expect(comments.count == 1)
    #expect(comments.first?.id == "def")
    #expect(comments.first?.author == "alice")
    #expect(comments.first?.body == "Tom & Jerry\n\nSecond")
    #expect(comments.first?.score == nil)
}

@Test func keepsHackerNewsNestingAndCapsDepth() {
    var node: [String: Any] = ["id": 9, "author": "deep", "text": "leaf", "children": [[String: Any]]()]
    for id in (1..<9).reversed() {
        node = ["id": id, "author": "x", "text": "t", "children": [node]]
    }
    var comments: [AggregatorComment] = []
    AggregatorService.appendHNThread(node, depth: 0, to: &comments)
    #expect(comments.count == AggregatorService.maxCommentDepth + 1)
    #expect(comments.last?.depth == AggregatorService.maxCommentDepth)
}

@Test func readsLobstersDepthAndLimitsTopLevelThreads() {
    let items: [[String: Any]] = [
        ["short_id": "a", "commenting_user": "ann", "comment": "<p>top</p>", "depth": 0, "parent_comment": NSNull()],
        ["short_id": "a1", "commenting_user": "bo", "comment": "<p>reply</p>", "depth": 1, "parent_comment": "a"],
        ["short_id": "b", "commenting_user": "cy", "comment": "", "depth": 0, "parent_comment": NSNull()],
        ["short_id": "b1", "commenting_user": "di", "comment": "<p>orphan</p>", "depth": 1, "parent_comment": "b"],
        ["short_id": "c", "commenting_user": "ed", "comment": "<p>third</p>", "depth": 0, "parent_comment": NSNull()]
    ]
    #expect(AggregatorService.lobstersComments(items, limit: 10).map(\.id) == ["a", "a1", "c"])
    #expect(AggregatorService.lobstersComments(items, limit: 1).count == 2)
}

@Test func rebuildsCommentThreadsFromFlatList() {
    let flat = [
        AggregatorComment(id: "a", author: "x", body: "", depth: 0),
        AggregatorComment(id: "a1", author: "x", body: "", depth: 1),
        AggregatorComment(id: "a11", author: "x", body: "", depth: 2),
        AggregatorComment(id: "a2", author: "x", body: "", depth: 1),
        AggregatorComment(id: "b", author: "x", body: "", depth: 0)
    ]
    let threads = AggregatorCommentThread.threads(from: flat)
    #expect(threads.map(\.id) == ["a", "b"])
    #expect(threads[0].replies.map(\.id) == ["a1", "a2"])
    #expect(threads[0].replyCount == 3)
}

@Test func keepsParagraphBreaksInCommentHTML() {
    #expect(AggregatorService.commentText(fromHTML: "First &amp; one<p>Second<br>line") == "First & one\n\nSecond\nline")
}
