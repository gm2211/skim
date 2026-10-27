import Foundation
import Testing
@testable import SkimCore

@Test func htmlEntitiesDecodesCurlyPunctuation() {
    // The bug: minimaxir.com reached the iOS reader as "Let&rsquo;s".
    #expect("Let&rsquo;s talk".decodingHTMLEntities == "Let\u{2019}s talk")
    #expect("&ldquo;quoted&rdquo;".decodingHTMLEntities == "\u{201C}quoted\u{201D}")
    #expect("a&mdash;b &hellip; c&ndash;d".decodingHTMLEntities == "a—b … c–d")
}

@Test func htmlEntitiesDecodesTheXMLFiveAndNumericForms() {
    #expect("a &amp; b &lt;tag&gt; &quot;q&quot; &apos;p&apos;".decodingHTMLEntities == "a & b <tag> \"q\" 'p'")
    #expect("&#8217;&#x2019;&#39;".decodingHTMLEntities == "\u{2019}\u{2019}'")
}

@Test func htmlEntitiesDecodesEachEntityOnlyOnce() {
    // An escaped entity is literal text, not something to decode twice.
    #expect("&amp;rsquo;".decodingHTMLEntities == "&rsquo;")
}

@Test func htmlEntitiesLeavesNonEntitiesAlone() {
    #expect("Tom & Jerry".decodingHTMLEntities == "Tom & Jerry")
    #expect("cost: 5 & rising; really".decodingHTMLEntities == "cost: 5 & rising; really")
    #expect("&notanentity; &; &#; &#zz;".decodingHTMLEntities == "&notanentity; &; &#; &#zz;")
    #expect("plain text".decodingHTMLEntities == "plain text")
}

@Test func storyTextDecodesNamedPunctuationEntities() {
    #expect(StoryText.excerpt("Let&rsquo;s read").contains("Let\u{2019}s read"))
}
