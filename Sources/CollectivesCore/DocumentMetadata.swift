import Foundation

extension CollectivesClient {
    public func documentETags(pages: [Page]) async throws -> [Int: String] {
        var folders: [URL: [Page]] = [:]
        for page in pages {
            let folder = try documentURL(page: page).deletingLastPathComponent()
            folders[folder, default: []].append(page)
        }
        var revisions: [Int: String] = [:]
        // A single conditional GET costs less than a folder listing followed by a GET.
        for folder in folders.keys.sorted(by: { $0.absoluteString < $1.absoluteString }) {
            try Task.checkCancellation()
            let children = folders[folder]!
            guard Set(children.map(\.id)).count > 1 else { continue }
            var request = try documentRequest(page: children[0])
            request.url = folder.appendingPathComponent("")
            request.httpMethod = "PROPFIND"
            request.setValue("1", forHTTPHeaderField: "Depth")
            request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue("application/xml", forHTTPHeaderField: "Accept")
            request.httpBody = Data("<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:getetag/></d:prop></d:propfind>".utf8)
            let (data, response) = try await sendDocumentMetadata(request)
            guard response.statusCode == 207 else { throw CollectivesError.http(response.statusCode) }
            let entries = try DAVDocumentMetadata.parse(data)
            var etagsByPath: [String: String] = [:]
            var seenPaths: Set<String> = []
            for entry in entries {
                guard let url = URL(string: entry.href, relativeTo: request.url)?.absoluteURL,
                      ServerAddress.isTrusted(url, server: account.serverURL),
                      url.query == nil, url.fragment == nil else { continue }
                let path = url.path
                // Ambiguous duplicate responses must never suppress a content check.
                if !seenPaths.insert(path).inserted { etagsByPath[path] = nil }
                else { etagsByPath[path] = entry.etag }
            }
            for page in children {
                revisions[page.id] = etagsByPath[try documentURL(page: page).path]
            }
        }
        return revisions
    }
}

private final class DAVDocumentMetadata: NSObject, XMLParserDelegate {
    struct Entry {
        let href: String
        let etag: String?
    }
    private var elements: [String] = []
    private var text = ""
    private var href = ""
    private var etag: String?
    private var propertyETag: String?
    private var propertyStatus = ""
    private var entries: [Entry] = []
    private var validRoot = false

    static func parse(_ data: Data) throws -> [Entry] {
        let delegate = DAVDocumentMetadata()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.validRoot else { throw CollectivesError.invalidResponse }
        return delegate.entries
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let name = namespaceURI == "DAV:" ? elementName : ""
        elements.append(name)
        text = ""
        if elements == ["multistatus"] { validRoot = true }
        if elements == ["multistatus", "response"] { href = ""; etag = nil }
        if elements == ["multistatus", "response", "propstat"] {
            propertyETag = nil; propertyStatus = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elements {
        case ["multistatus", "response", "href"]: href = value
        case ["multistatus", "response", "propstat", "prop", "getetag"]: propertyETag = value
        case ["multistatus", "response", "propstat", "status"]: propertyStatus = value
        case ["multistatus", "response", "propstat"]:
            if propertyStatus.split(separator: " ").dropFirst().first == "200",
               let propertyETag, !propertyETag.isEmpty { etag = propertyETag }
        case ["multistatus", "response"]:
            if !href.isEmpty { entries.append(Entry(href: href, etag: etag)) }
        default: break
        }
        elements.removeLast()
        text = ""
    }
}
