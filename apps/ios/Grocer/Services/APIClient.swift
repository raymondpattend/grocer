import Foundation
import Observation

/// Thin client for the Cloudflare Worker API.
///
/// The API is OPTIONAL. CloudKit is the source of truth for grocery data; the
/// API only powers suggestions, parsing, feedback, remote config, and APNs
/// Live Activity push fan-out. Every call is best-effort and failures are
/// swallowed (logged) so they never block the grocery workflow.
actor APIClient {
    static let shared = APIClient()
    #if DEBUG
    static let baseURLString = "https://grocer-75.localcan.dev"
    #else
    static let baseURLString = "https://grocer.narro.org"
    #endif

    /// Override with your deployed Worker URL. For the simulator, the default
    /// localhost works against `wrangler dev`.
    private let baseURL: URL

    init(baseURL: URL = URL(string: APIClient.baseURLString)!) {
        self.baseURL = baseURL
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Health / config

    func config(currentBuild: Int? = nil) async -> IOSConfig? {
        var query: [String: String] = [:]
        if let currentBuild {
            query["build"] = String(currentBuild)
        }
        return await get("/config/ios", query: query)
    }

    func health() async -> Bool {
        struct Health: Decodable { let ok: Bool }
        let h: Health? = await get("/health")
        return h?.ok ?? false
    }

    // MARK: - Suggestions & parsing

    func suggestions(query: String, recent: [String]) async -> [Suggestion] {
        struct Req: Encodable { let query: String; let recentItems: [String] }
        struct Res: Decodable { let suggestions: [Suggestion] }
        let res: Res? = await post("/suggestions/items", body: Req(query: query, recentItems: recent))
        return res?.suggestions ?? []
    }

    func parseList(_ text: String) async -> [ParsedItem] {
        struct Req: Encodable { let text: String }
        struct Res: Decodable { let items: [ParsedItem] }
        let res: Res? = await post("/parse-list", body: Req(text: text))
        return res?.items ?? []
    }

    // MARK: - Product images

    /// Best-effort: ask the API to pre-generate product images for the given
    /// item names so they're a cache hit by the time they scroll into view.
    /// Fire-and-forget — the server returns immediately and generates in the
    /// background.
    func prewarmImages(_ names: [String]) async {
        let trimmed = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return }
        struct Req: Encodable { let names: [String] }
        let _: OkResponse? = await post("/product-image/prewarm", body: Req(names: trimmed))
    }

    // MARK: - Feedback

    func sendFeedback(message: String, email: String?, appVersion: String?, device: String?) async -> Bool {
        struct Req: Encodable { let message: String; let email: String?; let appVersion: String?; let device: String? }
        let res: OkResponse? = await post("/feedback", body: Req(message: message, email: email, appVersion: appVersion, device: device))
        return res?.ok ?? false
    }

    // MARK: - Live Activity push coordination

    func registerPushToStart(_ payload: RegisterTokenPayload) async {
        let _: OkResponse? = await post("/live-activity/register-token", body: payload)
    }

    func registerUpdateToken(_ payload: RegisterUpdateTokenPayload) async {
        let _: OkResponse? = await post("/live-activity/register-update-token", body: payload)
    }

    @discardableResult
    func startLiveActivity(_ payload: StartLiveActivityPayload) async -> FanoutResponse? {
        await post("/live-activity/start", body: payload)
    }

    func updateLiveActivity(_ payload: UpdateLiveActivityPayload) async {
        let _: FanoutResponse? = await post("/live-activity/update", body: payload)
    }

    @discardableResult
    func endLiveActivity(_ payload: EndLiveActivityPayload) async -> FanoutResponse? {
        await post("/live-activity/end", body: payload)
    }

    // MARK: - Transport

    private func get<T: Decodable>(
        _ path: String,
        query: [String: String] = [:]
    ) async -> T? {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty {
            components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        return await perform(req)
    }

    private func post<T: Decodable>(_ path: String, body: some Encodable) async -> T? {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            req.httpBody = try encoder.encode(body)
        } catch {
            print("[APIClient] encode failed for \(path): \(error)")
            return nil
        }
        return await perform(req)
    }

    private func perform<T: Decodable>(_ req: URLRequest) async -> T? {
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                print("[APIClient] non-2xx for \(req.url?.path ?? "")")
                return nil
            }
            return try decoder.decode(T.self, from: data)
        } catch {
            // Best-effort: never surface API errors into the grocery workflow.
            print("[APIClient] request failed for \(req.url?.path ?? ""): \(error)")
            return nil
        }
    }
}

// MARK: - DTOs (mirror packages/shared/src/schemas.ts)

struct IOSConfig: Decodable {
    struct Features: Decodable {
        let suggestions: Bool
        let parseList: Bool
        let feedback: Bool
        let liveActivities: Bool
    }
    let minimumSupportedBuild: Int
    let latestBuild: Int
    /// Optional: older/leaner server responses omit this field. When absent we
    /// fall back to comparing the running build against `minimumSupportedBuild`
    /// rather than failing the whole decode (which silently disabled the
    /// update gate). Read through `requiresUpgrade(currentBuild:)`.
    let upgradeRequired: Bool?
    let status: String
    let updateUrl: String
    let features: Features

    var updateURL: URL? {
        URL(string: updateUrl)
    }

    /// Whether the running build must be upgraded. Prefers the server's explicit
    /// flag; otherwise derives it from the minimum supported build.
    func requiresUpgrade(currentBuild: Int) -> Bool {
        upgradeRequired ?? (currentBuild < minimumSupportedBuild)
    }
}

struct RequiredAppUpdate: Identifiable, Equatable {
    let id = "required-app-update"
    let updateURL: URL
    let currentBuild: Int
    let minimumSupportedBuild: Int
    let latestBuild: Int
}

@MainActor
@Observable
final class AppUpdateGate {
    static let shared = AppUpdateGate()

    private(set) var requiredUpdate: RequiredAppUpdate?
    private var isChecking = false

    private init() {}

    func refresh() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let currentBuild = Self.currentBuild
        guard let config = await APIClient.shared.config(currentBuild: currentBuild) else { return }

        guard config.requiresUpgrade(currentBuild: currentBuild) else {
            requiredUpdate = nil
            return
        }

        guard let updateURL = config.updateURL else {
            print("[AppUpdateGate] invalid updateUrl in iOS config")
            return
        }

        requiredUpdate = RequiredAppUpdate(
            updateURL: updateURL,
            currentBuild: currentBuild,
            minimumSupportedBuild: config.minimumSupportedBuild,
            latestBuild: config.latestBuild
        )
    }

    private static var currentBuild: Int {
        let raw = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return raw.flatMap(Int.init) ?? 0
    }
}

struct Suggestion: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let quantity: String?
    let unit: String?
    let category: String
    let notes: String?
}

struct ParsedItem: Decodable {
    let name: String
    let category: String
    let quantity: String?
    let unit: String?
}

struct OkResponse: Decodable { let ok: Bool }
struct FanoutResponse: Decodable {
    let ok: Bool
    let sent: Int
    let failed: Int
    let notificationsSent: Int?
    let notificationsFailed: Int?
}

struct RegisterTokenPayload: Encodable {
    let householdId: String
    let memberId: String
    let deviceId: String
    let pushToStartToken: String?
    let pushNotificationToken: String?
    let familyLiveActivitiesEnabled: Bool
    let notificationsEnabled: Bool?
    let appVersion: String
    let platform = "iOS"
}

struct RegisterUpdateTokenPayload: Encodable {
    let householdId: String
    let memberId: String
    let deviceId: String
    let sessionId: String
    let updateToken: String
}

struct StartLiveActivityPayload: Encodable {
    let householdId: String
    let sessionId: String
    let startedByMemberId: String
    let sourceDeviceId: String
    let storeName: String?
    let shopperName: String
    let status: String
    let itemsFound: Int
    let itemsRemaining: Int
    let totalItems: Int
    let outOfStockCount: Int
    let replacedCount: Int
    let lastHandledItemName: String?
    let lastHandledItemStatus: String?
    let startedAt: String
}

struct UpdateLiveActivityPayload: Encodable {
    let householdId: String
    let sessionId: String
    let storeName: String?
    let shopperName: String
    let status: String
    let itemsFound: Int
    let itemsRemaining: Int
    let totalItems: Int
    let outOfStockCount: Int
    let replacedCount: Int
    let lastHandledItemName: String?
    let lastHandledItemStatus: String?
    let updatedAt: String
}

struct EndLiveActivityPayload: Encodable {
    let householdId: String
    let sessionId: String
    let sourceDeviceId: String
    let storeName: String?
    let shopperName: String
    let status: String // "completed" | "cancelled"
    let itemsFound: Int
    let itemsRemaining: Int
    let totalItems: Int
    let outOfStockCount: Int
    let replacedCount: Int
    let endedAt: String
}
