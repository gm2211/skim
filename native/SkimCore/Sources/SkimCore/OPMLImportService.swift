import Foundation

public protocol ImportService: Sendable {
    func parseOPML(data: Data) throws -> [ImportedFeed]
}

public struct OPMLImportService: ImportService {
    public init() {}

    public func parseOPML(data: Data) throws -> [ImportedFeed] {
        let parser = XMLParser(data: data)
        let delegate = OPMLParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw SkimCoreError.invalidOPML
        }
        let feeds = Array(Set(delegate.feeds)).sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        if feeds.isEmpty {
            throw SkimCoreError.invalidOPML
        }
        return feeds
    }
}

private final class OPMLParserDelegate: NSObject, XMLParserDelegate {
    var feeds: [ImportedFeed] = []
    private var categories: [String?] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        guard elementName.lowercased() == "outline" else { return }
        let parent = categories.last ?? nil
        let xml = attributes["xmlUrl"] ?? attributes["xmlurl"] ?? attributes["url"]
        let text = attributes["text"].flatMap { $0.isEmpty ? nil : $0 } ?? attributes["title"]
        // Desktop OPML imports use the nearest enclosing category, not a joined path.
        categories.append(xml == nil ? text : parent)
        guard let xml, let xmlURL = URL(string: xml)?.upgradingHTTPToHTTPS() else { return }
        let html = attributes["htmlUrl"] ?? attributes["htmlurl"]
        feeds.append(ImportedFeed(
            title: text ?? xmlURL.host ?? xml,
            xmlURL: xmlURL,
            htmlURL: html.flatMap { URL(string: $0)?.upgradingHTTPToHTTPS() },
            opmlCategory: parent
        ))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName.lowercased() == "outline" { _ = categories.popLast() }
    }
}
