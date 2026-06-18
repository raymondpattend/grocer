import Foundation

/// Builds and parses the public-facing invite links served at
/// `share.grocer.sh/<token>`.
///
/// The token is the underlying CloudKit share URL, base64url-encoded, so the
/// app can recover it from an incoming Universal Link and accept the share. The
/// `group` and `inviter` query items drive the copy on the web landing page
/// (`apps/web`) that people without the app see — they download Grocer, reopen
/// the link, and the Universal Link then carries them into `ShareCoordinator`.
enum ShareInviteLink {
    static let host = "share.grocer.sh"

    /// Wraps a CloudKit share URL into a branded `share.grocer.sh` link.
    /// Returns `nil` only if the share URL can't be encoded, in which case
    /// callers should fall back to sharing the raw CloudKit URL.
    static func url(shareURL: URL, groupName: String?, inviterName: String?) -> URL? {
        guard let token = encode(shareURL) else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/" + token

        var items: [URLQueryItem] = []
        if let group = groupName?.trimmedNonEmpty {
            items.append(URLQueryItem(name: "group", value: group))
        }
        if let inviter = inviterName?.trimmedNonEmpty {
            items.append(URLQueryItem(name: "inviter", value: inviter))
        }
        components.queryItems = items.isEmpty ? nil : items

        return components.url
    }

    /// Recovers the CloudKit share URL from an incoming Universal Link, or
    /// `nil` if `url` isn't one of our share links.
    static func shareURL(from url: URL) -> URL? {
        guard url.host?.lowercased() == host else { return nil }
        let token = url.pathComponents.dropFirst().first ?? ""
        return decode(token)
    }

    // MARK: - Token codec

    static func encode(_ url: URL) -> String? {
        Data(url.absoluteString.utf8).base64URLEncodedString()
    }

    static func decode(_ token: String) -> URL? {
        guard !token.isEmpty,
              let data = Data(base64URLEncoded: token),
              let string = String(data: data, encoding: .utf8),
              let url = URL(string: string),
              url.scheme?.hasPrefix("http") == true
        else { return nil }
        return url
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private extension Data {
    /// URL-safe base64 with padding stripped — keeps the token clean inside a
    /// path segment.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        self.init(base64Encoded: base64)
    }
}
