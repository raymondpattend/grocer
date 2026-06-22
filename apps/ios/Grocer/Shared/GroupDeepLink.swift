import Foundation

enum GroupDeepLink {
    static let scheme = "grocer"
    private static let host = "group"
    /// Query item appended to ask the app to open the Add Items modal once the
    /// group's list is on screen (used by the home-screen widget's Add button).
    private static let actionQueryName = "action"
    private static let addActionValue = "add"

    static func url(householdId: String) -> URL? {
        components(householdId: householdId)?.url
    }

    /// Like `url(householdId:)` but tags the link so the app jumps straight into
    /// the Add Items modal for that list.
    static func addURL(householdId: String) -> URL? {
        guard var components = components(householdId: householdId) else { return nil }
        components.queryItems = [URLQueryItem(name: actionQueryName, value: addActionValue)]
        return components.url
    }

    static func householdId(from url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        let pathId = url.pathComponents.dropFirst().first
        let id = url.host == host ? pathId : url.host
        return id?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    /// Whether the link asks to open the Add Items modal (see `addURL`).
    static func wantsAddItem(from url: URL) -> Bool {
        guard url.scheme == scheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return false
        }
        return items.contains { $0.name == actionQueryName && $0.value == addActionValue }
    }

    private static func components(householdId: String) -> URLComponents? {
        let trimmed = householdId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + trimmed
        return components
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
