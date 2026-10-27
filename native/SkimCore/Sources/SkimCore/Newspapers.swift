import Foundation

/// A major newspaper from shared/newspapers.json: its official RSS sections,
/// and the login page Skim opens so a subscriber's full articles load in the
/// reader. The paper's cookies are only ever sent to its own domains.
public struct Newspaper: Identifiable, Hashable, Sendable {
    public struct Section: Hashable, Sendable {
        public var title: String
        public var url: URL
    }

    public var id: String
    public var name: String
    public var site: URL
    public var domains: [String]
    public var isFree: Bool
    public var signIn: URL?
    /// The paper's login cookies, when known, so a lapsed sign-in shows.
    public var sessionCookies: [String]
    public var sections: [Section]
    /// Shown in place of the sections when the paper has none Skim can follow.
    public var note: String?

    /// Sections as Discover feed rows, titled by section.
    public var sectionFeeds: [DiscoveredFeed] {
        sections.map { DiscoveredFeed(url: $0.url, title: $0.title, siteURL: site) }
    }

    /// True when `host` is one of the paper's domains or a subdomain of one.
    public func owns(host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domains.contains { domain in
            let domain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return host == domain || host.hasSuffix("." + domain)
        }
    }

    /// Signed in: the paper's login cookie is present, or, for papers whose
    /// login cookie Skim does not know, the reader finished signing in and the
    /// paper still has cookies.
    public func isSignedIn(finishedSignIn: Bool, cookieNames: [String]) -> Bool {
        guard signIn != nil, !cookieNames.isEmpty else { return false }
        if sessionCookies.isEmpty { return finishedSignIn }
        return cookieNames.contains { sessionCookies.contains($0) }
    }

    /// True once the sign-in page has sent the reader on to the paper's own
    /// site, which is where every paper lands a reader who signed in.
    public func finishedSignIn(at url: URL) -> Bool {
        guard let host = url.host()?.lowercased(), host == site.host()?.lowercased() else { return false }
        let path = url.path().lowercased()
        return !["login", "signin", "sign-in", "subscribe", "account", "auth", "register"].contains { path.contains($0) }
    }
}

public struct NewspaperCatalog: Sendable {
    public var newspapers: [Newspaper]

    public init(newspapers: [Newspaper]) {
        self.newspapers = newspapers
    }

    public init(data: Data) throws {
        struct RawSection: Decodable { var title: String; var url: String }
        struct RawPaper: Decodable {
            var id: String
            var name: String
            var site: String
            var domains: [String]
            var access: String
            var signIn: String?
            var sessionCookies: [String]?
            var sections: [RawSection]
            var note: String?
        }
        struct Raw: Decodable { var newspapers: [RawPaper] }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        newspapers = raw.newspapers.compactMap { paper in
            guard let site = URL(string: paper.site) else { return nil }
            return Newspaper(
                id: paper.id,
                name: paper.name,
                site: site,
                domains: paper.domains,
                isFree: paper.access == "free",
                signIn: paper.signIn.flatMap(URL.init(string:)),
                sessionCookies: paper.sessionCookies ?? [],
                sections: paper.sections.compactMap { section in
                    URL(string: section.url).map { Newspaper.Section(title: section.title, url: $0) }
                },
                note: paper.note
            )
        }
    }

    public func newspaper(for url: URL) -> Newspaper? {
        guard let host = url.host() else { return nil }
        return newspapers.first { $0.owns(host: host) }
    }

    /// The `Cookie` header for a reader fetch of `url`: the cookies of the
    /// paper that published it, and nothing for any other site.
    public func cookieHeader(for url: URL, cookies: [(domain: String, name: String, value: String)]) -> String? {
        guard let paper = newspaper(for: url) else { return nil }
        var seen = Set<String>()
        let pairs = cookies
            .filter { paper.owns(host: $0.domain) && seen.insert($0.name).inserted }
            .map { "\($0.name)=\($0.value)" }
        return pairs.isEmpty ? nil : pairs.joined(separator: "; ")
    }
}
