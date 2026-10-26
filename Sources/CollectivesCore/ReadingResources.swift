import Foundation

public enum ReadingResources {
    public static func resolve(destination: String, documentURL: URL, account: Account) -> URL? {
        let value = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\\"),
              let url = URL(string: value, relativeTo: documentURL)?.absoluteURL.standardized,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.host != nil else { return nil }
        if parts.scheme?.lowercased() == "https" { return url }
        guard parts.scheme?.lowercased() == "http",
              (try? ServerAddress.normalize(account.serverURL)) != nil,
              sameOrigin(url, account.serverURL), account.serverURL.scheme == "http" else { return nil }
        return url
    }

    public static func pageID(for url: URL, pages: [Page], account: Account) -> Int? {
        guard sameOrigin(url, account.serverURL), url.user == nil, url.password == nil,
              url.query == nil, let target = canonicalPath(url) else { return nil }
        return pages.first { page in
            guard let collectivePath = page.collectivePath,
                  let server = try? ServerAddress.normalize(account.serverURL),
                  let document = try? ServerAddress.append(
                    ["remote.php", "dav", "files", account.userID]
                    + (collectivePath + "/" + page.filePath).split(separator: "/").map(String.init)
                    + [page.fileName], to: server) else { return false }
            return canonicalPath(document) == target
        }?.id
    }

    public static func canLoadImage(at url: URL, account: Account) -> Bool {
        guard let server = try? ServerAddress.normalize(account.serverURL),
              sameOrigin(url, server), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              let root = try? ServerAddress.append(["remote.php", "dav", "files", account.userID], to: server),
              let path = canonicalPath(url), let rootPath = canonicalPath(root) else { return false }
        return path.hasPrefix(rootPath + "/")
    }

    private static func sameOrigin(_ first: URL, _ second: URL) -> Bool {
        first.scheme?.lowercased() == second.scheme?.lowercased()
            && first.host?.lowercased() == second.host?.lowercased()
            && (first.port ?? (first.scheme == "https" ? 443 : 80))
                == (second.port ?? (second.scheme == "https" ? 443 : 80))
    }

    private static func canonicalPath(_ url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var components: [String] = []
        for segment in parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false) {
            guard let decoded = String(segment).removingPercentEncoding,
                  decoded != ".", decoded != "..", !decoded.contains("/"),
                  !decoded.contains("\\"), !decoded.contains("\0") else { return nil }
            components.append(decoded)
        }
        return components.joined(separator: "/")
    }
}
