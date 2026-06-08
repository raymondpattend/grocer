import Foundation

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

    func config() async -> IOSConfig? {
        await get("/config/ios")
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
    let features: Features
}

struct Suggestion: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let quantity: String?
    let category: String
    let notes: String?
}

struct ParsedItem: Decodable {
    let name: String
    let category: String
    let quantity: String?
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
