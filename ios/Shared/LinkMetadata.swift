import Foundation

// MARK: - HTML metadata scraping

nonisolated enum LinkMetadata {
    /// Media URLs declared by a page, best first: animated sources, then stills.
    static func mediaCandidates(in html: String, baseURL: URL) -> [URL] {
        let metas = metaTags(in: html)
        let keys = [
            "og:image:gif", "twitter:image:gif",
            "og:image", "og:image:url", "og:image:secure_url",
            "twitter:image", "twitter:image:src",
        ]
        var urls: [URL] = []
        // Prefer anything that is explicitly a .gif.
        for (_, value) in metas where value.lowercased().contains(".gif") {
            if let url = URL(string: decode(value), relativeTo: baseURL)?.absoluteURL { urls.append(url) }
        }
        for key in keys {
            for (name, value) in metas where name == key {
                if let url = URL(string: decode(value), relativeTo: baseURL)?.absoluteURL { urls.append(url) }
            }
        }
        // Client-rendered pages (e.g. GIPHY) skip og tags but embed media URLs in their JSON.
        urls += embeddedGIFs(in: html, pageURL: baseURL)
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }

    /// Absolute .gif URLs in the page source. Ones whose path contains the page's
    /// slug ID come first, so related-GIF thumbnails don't win.
    static func embeddedGIFs(in html: String, pageURL: URL) -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: #"https:(?:\\?/){2}[^"'\s<>]+?\.gif(?=["'\s<>?\\])"#) else { return [] }
        let ns = html as NSString
        let found = regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).prefix(200).compactMap { match in
            URL(string: ns.substring(with: match.range).replacingOccurrences(of: "\\/", with: "/"))
        }
        // "/gifs/cat-funny-JIX9t2j0ZTN9S" → "JIX9t2j0ZTN9S"
        let slugID = pageURL.lastPathComponent.split(separator: "-").last.map(String.init) ?? ""
        guard slugID.count >= 6 else { return found }
        let matching = found.filter { $0.path().contains(slugID) }
        return matching + found.filter { !$0.path().contains(slugID) }
    }

    static func title(in html: String) -> String? {
        let metas = metaTags(in: html)
        if let og = metas.first(where: { $0.0 == "og:title" })?.1 { return clean(decode(og)) }
        guard
            let start = html.range(of: "<title", options: .caseInsensitive),
            let open = html[start.upperBound...].firstIndex(of: ">"),
            let end = html.range(of: "</title>", options: .caseInsensitive, range: open..<html.endIndex)
        else { return nil }
        return clean(decode(String(html[html.index(after: open)..<end.lowerBound])))
    }

    static func firstURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.firstMatch(in: text, range: range)?.url
    }

    /// (property-or-name, content) pairs, lowercased keys.
    static func metaTags(in html: String) -> [(String, String)] {
        let pattern = #"<meta\b[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let tag = ns.substring(with: match.range)
            guard let key = attribute("property", in: tag) ?? attribute("name", in: tag),
                  let content = attribute("content", in: tag) else { return nil }
            return (key.lowercased(), content)
        }
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for group in 1...2 {
            if let range = Range(match.range(at: group), in: tag) { return String(tag[range]) }
        }
        return nil
    }

    static func decode(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    private static func clean(_ title: String) -> String? {
        // "Run Away GIF - Run Away Zoo - Discover & Share GIFs" → "Run Away".
        var value = title.trimmed
        for separator in [" - ", " | ", " — ", " – "] {
            if let range = value.range(of: separator), range.lowerBound > value.startIndex {
                value = String(value[..<range.lowerBound])
            }
        }
        for suffix in [" GIF", " GIFs", " Sticker"] where value.lowercased().hasSuffix(suffix.lowercased()) {
            value = String(value.dropLast(suffix.count))
        }
        value = value.trimmed
        return value.isEmpty ? nil : String(value.prefix(80))
    }
}
