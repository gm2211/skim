import Testing
import Foundation
@testable import Skim

// MARK: - NativeWebSearch.parseDDGResults Tests
//
// The chat's web_search tool scrapes html.duckduckgo.com. Its result
// containers carry class="links_main links_deep result__body", which the
// old split on `class="result__body` never matched, so every search came
// back with one result. Mirrors the Rust tests in src-tauri chat.rs.
@Suite("NativeWebSearch.parseDDGResults")
struct NativeWebSearchTests {

    static let html = """
    <div class="result results_links results_links_deep result--ad ">
      <div class="links_main links_deep result__body">
        <h2 class="result__title"><a rel="nofollow" class="result__a" href="https://duckduckgo.com/y.js?ad_domain=example.com&amp;ad_provider=bing">Cheap <b>VPS</b> Hosting</a></h2>
        <a class="result__snippet" href="https://duckduckgo.com/y.js?ad_domain=example.com">Sponsored</a>
      </div>
    </div>
    <div class="result results_links results_links_deep web-result ">
      <div class="links_main links_deep result__body">
        <h2 class="result__title"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.digitalocean.com%2Fpricing%2Fdroplets&amp;rut=abc">Droplet Pricing | <b>DigitalOcean</b></a></h2>
        <a class="result__snippet" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.digitalocean.com%2Fpricing%2Fdroplets">Basic Droplets start at $4/mo &amp; scale up.</a>
      </div>
    </div>
    <div class="result results_links results_links_deep web-result ">
      <div class="links_main links_deep result__body">
        <h2 class="result__title"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.digitalocean.com%2Fpricing%2Fkubernetes&amp;rut=def">Kubernetes Pricing | DigitalOcean</a></h2>
        <a class="result__snippet" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.digitalocean.com%2Fpricing%2Fkubernetes">The control plane is free; you pay for worker nodes.</a>
      </div>
    </div>
    <div class="result results_links results_links_deep web-result ">
      <div class="links_main links_deep result__body">
        <h2 class="result__title"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.digitalocean.com%2Fpricing%2Fdroplets&amp;rut=ghi">Droplet Pricing (duplicate)</a></h2>
      </div>
    </div>
    <div class="result results_links results_links_deep web-result ">
      <div class="links_main links_deep result__body">
        <h2 class="result__title"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.org%2Fvps-compare&amp;rut=jkl">VPS price comparison</a></h2>
      </div>
    </div>
    """

    @Test func returnsEveryOrganicResult() {
        let results = NativeWebSearch.parseDDGResults(Self.html)
        #expect(results.map(\.url) == [
            "https://www.digitalocean.com/pricing/droplets",
            "https://www.digitalocean.com/pricing/kubernetes",
            "https://example.org/vps-compare",
        ])
        #expect(results.first?.title == "Droplet Pricing | DigitalOcean")
        #expect(results.first?.snippet == "Basic Droplets start at $4/mo & scale up.")
        #expect(results.last?.snippet == "")
    }

    @Test func detectsBotCheck() {
        let page = #"<div class="anomaly-modal__title">Unfortunately, bots use DuckDuckGo too.</div>"#
        #expect(NativeWebSearch.parseDDGResults(page).isEmpty)
        #expect(NativeWebSearch.isDDGChallenge(status: 200, html: page))
        #expect(NativeWebSearch.isDDGChallenge(status: 202, html: ""))
        #expect(!NativeWebSearch.isDDGChallenge(status: 200, html: Self.html))
    }
}
