import Testing
import Foundation
@testable import Skim

// MARK: - ArticleExtractor Tests

/// Tests for JSON-LD articleBody extraction (skim-9m0).
///
/// HackerNoon is a client-rendered Next.js site whose server HTML contains only
/// nav/byline/related-stories chrome in the visible DOM; the real article text
/// lives inside a `<script type="application/ld+json">` block as `articleBody`.
/// These tests verify that the extractor retrieves that content before the
/// `<script>` stripping pass destroys it.
@Suite("ArticleExtractor")
struct ArticleExtractorTests {

    // MARK: - Helpers

    private static func fixtureURL(named name: String) -> URL? {
        // In a test bundle the fixture sits next to the compiled test binary
        // under the bundle's resources root.
        let bundle = Bundle(for: BundleLocator.self)
        if let url = bundle.url(forResource: name, withExtension: nil) {
            return url
        }
        // Fallback: look relative to the source file (for SPM / command-line builds)
        let sourceDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let relative = sourceDir.appendingPathComponent("Fixtures/\(name)")
        return FileManager.default.fileExists(atPath: relative.path) ? relative : nil
    }

    // MARK: - Test cases

    /// skim-9m0: HackerNoon fixture must extract via JSON-LD articleBody.
    /// The fixture is ~184 KB server HTML from a Next.js page where the DOM body
    /// is shell-only; `articleBody` is the only usable content.
    @Test func testHackerNoonJSONLDExtraction() throws {
        guard let url = Self.fixtureURL(named: "hackernoon-9m0.html"),
              let html = try? String(contentsOf: url, encoding: .utf8)
        else {
            Issue.record("hackernoon-9m0.html fixture not found — run the curl command in the bd description to generate it")
            return
        }

        let baseURL = URL(string: "https://hackernoon.com/scaling-on-chain-yield-what-comes-next-for-btc-and-eth")!
        let text = try ArticleExtractor.extract(from: html, baseURL: baseURL)

        #expect(text.count > 1000, "Expected extracted text length > 1000, got \(text.count)")
        #expect(
            text.localizedCaseInsensitiveContains("on-chain yield"),
            "Expected article text to contain 'on-chain yield'"
        )
    }

    /// Regression: a page with a real `<article>` tag and NO JSON-LD must still
    /// extract via the existing DOM path (the new JSON-LD path must not break it).
    @Test func testFallbackUnaffected_articleTag() throws {
        let longProse = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 20)
        let html = """
        <!DOCTYPE html>
        <html>
          <body>
            <article>
              <h1>Test Article</h1>
              <p>\(longProse)</p>
            </article>
          </body>
        </html>
        """

        let baseURL = URL(string: "https://example.com/test")!
        let text = try ArticleExtractor.extract(from: html, baseURL: baseURL)

        #expect(text.count > 200, "Expected article-tag extraction to return text, got \(text.count)")
        #expect(text.localizedCaseInsensitiveContains("quick brown fox"))
    }

    /// Regression: a page with only `<main>` containing junk markup should still
    /// throw `.contentLooksLikeMarkup` — the new path must not suppress that.
    @Test func testNoJSONLDNoArticleStillThrows() {
        let junkMain = """
        <!DOCTYPE html>
        <html>
          <body>
            <main>
              [&gt;:h-full w-full mb-4 max-h-full overflow-hidden rounded-[8px] ]:h-full
              [&gt;:h-full w-full mb-4 max-h-full overflow-hidden rounded-[8px] ]:h-full
              [&gt;:h-full w-full mb-4 max-h-full overflow-hidden rounded-[8px] ]:h-full
              [&gt;:h-full w-full mb-4 max-h-full overflow-hidden rounded-[8px] ]:h-full
            </main>
          </body>
        </html>
        """

        let baseURL = URL(string: "https://example.com/junk")!
        #expect(throws: ArticleExtractor.Error.contentLooksLikeMarkup) {
            try ArticleExtractor.extract(from: junkMain, baseURL: baseURL)
        }
    }

    // MARK: - Unit tests for extractJSONLDArticleBody

    /// JSON-LD with a plain top-level Article node.
    @Test func testJSONLDTopLevelArticleNode() throws {
        let body = String(repeating: "Real article content. ", count: 12)
        let html = """
        <html><head>
        <script type="application/ld+json">
        {
          "@context": "https://schema.org",
          "@type": "NewsArticle",
          "articleBody": "\(body)"
        }
        </script>
        </head><body><main>Nothing useful here.</main></body></html>
        """
        let baseURL = URL(string: "https://example.com/news")!
        let text = try ArticleExtractor.extract(from: html, baseURL: baseURL)
        #expect(text.localizedCaseInsensitiveContains("Real article content"))
    }

    /// JSON-LD with a @graph array — articleBody inside one of the nodes.
    @Test func testJSONLDGraphArray() throws {
        let body = String(repeating: "Graph-wrapped article body text here. ", count: 12)
        let html = """
        <html><head>
        <script type="application/ld+json">
        {
          "@context": "https://schema.org",
          "@graph": [
            { "@type": "WebSite", "name": "TestSite" },
            { "@type": "BlogPosting", "headline": "My Post", "articleBody": "\(body)" }
          ]
        }
        </script>
        </head><body><main>Shell only.</main></body></html>
        """
        let baseURL = URL(string: "https://example.com/blog")!
        let text = try ArticleExtractor.extract(from: html, baseURL: baseURL)
        #expect(text.localizedCaseInsensitiveContains("Graph-wrapped article body"))
    }

    /// JSON-LD articleBody shorter than 200 chars must be ignored (too thin to be useful).
    @Test func testJSONLDShortBodyIgnored() {
        let html = """
        <html><head>
        <script type="application/ld+json">
        { "@type": "Article", "articleBody": "Short." }
        </script>
        </head><body><main>Also useless garbage &lt;&gt; &amp; {{{ [] }}}</main></body></html>
        """
        let baseURL = URL(string: "https://example.com/thin")!
        // The JSON-LD body is too short; fallback to DOM also returns garbage — must throw.
        #expect(throws: ArticleExtractor.Error.contentLooksLikeMarkup) {
            try ArticleExtractor.extract(from: html, baseURL: baseURL)
        }
    }
}

/// Dummy class used only to locate the test bundle via `Bundle(for:)`.
private final class BundleLocator {}
