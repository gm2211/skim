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

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName.lowercased() == "outline" else { return }
        let xml = attributeDict["xmlUrl"] ?? attributeDict["xmlurl"] ?? attributeDict["url"]
        guard let xml, let xmlURL = URL(string: xml) else { return }
        let title = attributeDict["title"] ?? attributeDict["text"] ?? xmlURL.host ?? xml
        let html = attributeDict["htmlUrl"] ?? attributeDict["htmlurl"]
        feeds.append(ImportedFeed(title: title, xmlURL: xmlURL, htmlURL: html.flatMap(URL.init(string:))))
    }
}
