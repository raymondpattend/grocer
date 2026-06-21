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

    /// How long a generated invite link is honored before the app refuses it.
    /// This is **not** a security boundary — the `exp` query item is plaintext
    /// and anyone can strip it — but it quietly stops casual reuse of a long-
    /// stale link. Kept in step with the owner-side public-share rotation window
    /// (`GroceryRepository.rotateStaleInviteLinks`) so a link and the share
    /// behind it expire at roughly the same time.
    static let defaultValidity: TimeInterval = 7 * 24 * 60 * 60

    /// Wraps a CloudKit share URL into a branded `share.grocer.sh` link.
    /// Returns `nil` only if the share URL can't be encoded, in which case
    /// callers should fall back to sharing the raw CloudKit URL.
    ///
    /// When `expiresAt` is provided it's encoded as an `exp` query item (Unix
    /// seconds); `isExpired(_:)` reads it back on the acceptance side.
    static func url(shareURL: URL, groupName: String?, inviterName: String?, expiresAt: Date? = nil) -> URL? {
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
        if let expiresAt {
            items.append(URLQueryItem(name: "exp", value: String(Int(expiresAt.timeIntervalSince1970))))
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

    /// The expiry carried in a branded link's `exp` query item, or nil if the
    /// link has none (older links) or isn't one of ours.
    static func expiry(from url: URL) -> Date? {
        guard url.host?.lowercased() == host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let raw = items.first(where: { $0.name == "exp" })?.value,
              let seconds = TimeInterval(raw) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// True only when the link carries an `exp` that has already passed. Links
    /// without an expiry (older builds) are treated as still valid.
    static func isExpired(_ url: URL, now: Date = Date()) -> Bool {
        guard let expiry = expiry(from: url) else { return false }
        return expiry < now
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
