import Foundation
import CryptoKit
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
    static let baseURLString = "https://api.grocer.sh"
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

    /// Slower session for AI calls that round-trip an image through a vision
    /// model (item identification), which routinely exceeds the 8s default.
    private let visionSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var liveActivityAPISecret: String {
        (Bundle.main.object(forInfoDictionaryKey: "GRLiveActivityAPISecret") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

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
        // Parsing runs an LLM server-side, which routinely exceeds the default 8s
        // session (especially cold, or over a dev tunnel like localcan) — use the
        // longer session so it doesn't time out into the on-device fallback.
        let res: Res? = await post("/parse-list", body: Req(text: text), session: visionSession)
        return res?.items ?? []
    }

    // MARK: - Item identification (vision)

    /// Sends a photo to the Worker's vision model. Returns the identified item(s)
    /// on success, or `.rateLimited` when the caller is over the AI quota (the
    /// view should show an actionable message rather than a silent empty result).
    /// The image is sent only to our Worker; it is NOT persisted server-side.
    func identifyItem(imageData: Data) async -> Result<IdentifyOutcome, APIError> {
        struct Req: Encodable { let image: String; let mimeType: String }
        struct Res: Decodable { let item: IdentifiedItem?; let items: [ParsedItem]? }
        var req = URLRequest(url: baseURL.appendingPathComponent("/identify-item"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(SettingsStore.shared.memberIdOrDevice, forHTTPHeaderField: "x-grocer-distinct-id")
        guard let body = try? encoder.encode(Req(image: imageData.base64EncodedString(), mimeType: "image/jpeg")) else {
            return .success(IdentifyOutcome(item: nil, items: []))
        }
        req.httpBody = body
        let (res, status): (Res?, Int) = await performWithStatus(req, session: visionSession)
        if status == 429 { return .failure(.rateLimited) }
        return .success(IdentifyOutcome(item: res?.item, items: res?.items ?? []))
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

    /// Tells the backend the full set of groups this device currently belongs
    /// to so it can disable registrations for groups the device has left —
    /// including ones abandoned while the app was closed.
    func syncRegistrations(_ payload: SyncRegistrationsPayload) async {
        let _: OkResponse? = await post("/live-activity/sync-registrations", body: payload)
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

    @discardableResult
    func sendHeadsUp(_ payload: HeadsUpPayload) async -> FanoutResponse? {
        await post("/live-activity/heads-up", body: payload)
    }

    // MARK: - Retention

    /// Foreground heartbeat — records that the user opened the app so the
    /// backend's retention cron knows how long they've been away.
    func reportActive(_ payload: HeartbeatPayload) async {
        let _: OkResponse? = await post("/retention/heartbeat", body: payload)
    }

    /// Records that the local member added items to a shared list, so other
    /// members can be nudged about them later if they go inactive.
    func reportListActivity(_ payload: ListActivityPayload) async {
        let _: OkResponse? = await post("/retention/activity", body: payload)
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
        req.setValue(SettingsStore.shared.memberIdOrDevice, forHTTPHeaderField: "x-grocer-distinct-id")
        return await perform(req)
    }

    private func post<T: Decodable>(_ path: String, body: some Encodable, session: URLSession? = nil) async -> T? {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Same identity the client uses for PostHogSDK.identify, so server-side
        // events (notably AI usage) attach to this person's profile.
        req.setValue(SettingsStore.shared.memberIdOrDevice, forHTTPHeaderField: "x-grocer-distinct-id")
        let bodyData: Data
        do {
            bodyData = try encoder.encode(body)
            req.httpBody = bodyData
        } catch {
            print("[APIClient] encode failed for \(path): \(error)")
            return nil
        }
        if path.hasPrefix("/live-activity") || path.hasPrefix("/retention"),
           !signLiveActivityRequest(&req, body: bodyData) {
            print("[APIClient] signed request skipped: missing API signing secret")
            return nil
        }
        return await perform(req, session: session)
    }

    private func signLiveActivityRequest(_ req: inout URLRequest, body: Data) -> Bool {
        let secret = liveActivityAPISecret
        guard !secret.isEmpty,
              let method = req.httpMethod,
              let path = req.url?.path,
              let secretData = secret.data(using: .utf8) else {
            return false
        }

        let timestamp = String(Int(Date().timeIntervalSince1970))
        var message = Data("\(timestamp).\(method).\(path).".utf8)
        message.append(body)
        let key = SymmetricKey(data: secretData)
        let signature = HMAC<SHA256>.authenticationCode(for: message, using: key)
            .map { String(format: "%02x", $0) }
            .joined()

        req.setValue(timestamp, forHTTPHeaderField: "x-grocer-timestamp")
        req.setValue(signature, forHTTPHeaderField: "x-grocer-signature")
        req.setValue(SettingsStore.shared.deviceId, forHTTPHeaderField: "x-grocer-device-id")
        return true
    }

    private func perform<T: Decodable>(_ req: URLRequest, session: URLSession? = nil) async -> T? {
        await performWithStatus(req, session: session).0
    }

    private func performWithStatus<T: Decodable>(_ req: URLRequest, session: URLSession? = nil) async -> (T?, Int) {
        do {
            let (data, response) = try await (session ?? self.session).data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                print("[APIClient] non-2xx (\(status)) for \(req.url?.path ?? "")")
                return (nil, status)
            }
            do {
                return (try decoder.decode(T.self, from: data), status)
            } catch {
                print("[APIClient] decode failed for \(req.url?.path ?? ""): \(error)")
                return (nil, status)
            }
        } catch {
            print("[APIClient] request failed for \(req.url?.path ?? ""): \(error)")
            return (nil, 0)
        }
    }
}

// MARK: - Errors

enum APIError: Error {
    case rateLimited
}

// MARK: - DTOs (mirror packages/shared/src/schemas.ts)

struct IOSConfig: Decodable {
    struct Features: Decodable {
        let suggestions: Bool
        let parseList: Bool
        let feedback: Bool
        let liveActivities: Bool
    }
    struct Payments: Decodable {
        let externalPurchaseStorefronts: [String]
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
    let payments: Payments?

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

/// One grocery item identified from a photo by the Worker's vision model.
struct IdentifiedItem: Decodable {
    let name: String
    let category: String
    /// Model's confidence in [0, 1], when provided.
    let confidence: Double?

    /// The detected category mapped onto the app enum, falling back to an
    /// on-device guess from the name when the server value is unrecognized.
    var groceryCategory: GroceryCategory {
        GroceryCategory(rawValue: category) ?? CategoryGuess.guess(for: name)
    }
}

/// One photo resolved by the Worker's vision model: either a single product or a
/// multi-item grocery list read off the photo. At most one side is populated;
/// both are empty when nothing grocery-related was found.
struct IdentifyOutcome {
    let item: IdentifiedItem?
    let items: [ParsedItem]
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
    /// Minutes east of UTC, so the retention cron can avoid night-time sends.
    var tzOffsetMinutes: Int = TimeZone.current.secondsFromGMT() / 60
}

struct HeartbeatPayload: Encodable {
    let householdId: String
    let memberId: String
    let deviceId: String
    var tzOffsetMinutes: Int = TimeZone.current.secondsFromGMT() / 60
}

struct ListActivityPayload: Encodable {
    let householdId: String
    let recipientMemberIds: [String]
    let actorMemberId: String
    let actorDisplayName: String?
    let deviceId: String
    let itemCount: Int
}

struct RegisterUpdateTokenPayload: Encodable {
    let householdId: String
    let memberId: String
    let deviceId: String
    let sessionId: String
    let updateToken: String
}

struct SyncRegistrationsPayload: Encodable {
    let deviceId: String
    let householdIds: [String]
}

struct StartLiveActivityPayload: Encodable {
    let householdId: String
    let sessionId: String
    let recipientMemberIds: [String]
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

struct HeadsUpPayload: Encodable {
    let householdId: String
    let recipientMemberIds: [String]
    let sourceDeviceId: String
    let shopperName: String
    let storeName: String?
    let sentAt: String
}

struct UpdateLiveActivityPayload: Encodable {
    let householdId: String
    let sessionId: String
    let recipientMemberIds: [String]
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
    let recipientMemberIds: [String]
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
