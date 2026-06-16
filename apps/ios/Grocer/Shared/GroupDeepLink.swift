import Foundation

enum GroupDeepLink {
    static let scheme = "grocer"
    private static let host = "group"

    static func url(householdId: String) -> URL? {
        let trimmed = householdId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + trimmed
        return components.url
    }

    static func householdId(from url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        let pathId = url.pathComponents.dropFirst().first
        let id = url.host == host ? pathId : url.host
        return id?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
