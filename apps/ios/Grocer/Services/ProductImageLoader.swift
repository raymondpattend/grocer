import SwiftUI

/// Fetches AI-generated product images from the API (which caches in R2)
/// and keeps an in-memory + on-disk cache so images load instantly on repeat views.
@Observable
@MainActor
final class ProductImageLoader {
    static let shared = ProductImageLoader()

    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private var memoryCache: [String: UIImage] = [:]

    func image(for itemName: String) async -> UIImage? {
        let key = itemName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }

        // Cache lookup is the only work that touches main-actor state.
        if let cached = memoryCache[key] { return cached }
        if let existing = inFlight[key] { return await existing.value }

        // All disk I/O, networking, and image decoding happen off the main
        // thread inside `load(key:)` (it's `nonisolated async`, so it runs on the
        // cooperative pool, not the main actor). We only hop back here to update
        // the caches, which is cheap.
        let task = Task<UIImage?, Never> { await Self.load(key: key) }
        inFlight[key] = task
        let result = await task.value
        inFlight.removeValue(forKey: key)
        if let result { memoryCache[key] = result }
        return result
    }

    /// Streaming variant: yields progressively-sharper partial images as the
    /// server generates them (via OpenAI's `partial_images` SSE), then the final
    /// image. Memory/disk-cached images are yielded immediately as a single
    /// frame. The final frame is written to both caches.
    ///
    /// Consume with `for await frame in loader.imageStream(for: name)` — the
    /// last frame is the finished image. The stream finishes with no frames if
    /// loading failed.
    func imageStream(for itemName: String) -> AsyncStream<(image: UIImage, isFinal: Bool)> {
        let key = itemName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return AsyncStream { continuation in
            guard !key.isEmpty else { continuation.finish(); return }

            // Fast path: already in memory.
            if let cached = memoryCache[key] {
                continuation.yield((cached, true))
                continuation.finish()
                return
            }

            let task = Task {
                // Disk cache (off the main thread).
                if let img = await Self.loadFromDisk(key: key) {
                    continuation.yield((img, true))
                    self.memoryCache[key] = img
                    continuation.finish()
                    return
                }

                // Network: relay partials as they arrive, return the final.
                let final = await Self.streamFromNetwork(key: key) { partial in
                    continuation.yield((partial, false))
                }
                let resolved: UIImage?
                if let final {
                    resolved = final
                } else if Task.isCancelled {
                    resolved = nil
                } else {
                    resolved = await self.image(for: key)
                }
                if let resolved {
                    continuation.yield((resolved, true))
                    self.memoryCache[key] = resolved
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Off-main-thread loading

    nonisolated private static func load(key: String) async -> UIImage? {
        // Disk cache (read + decode off the main thread).
        if let img = await loadFromDisk(key: key) { return img }

        // Network fetch.
        guard let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: APIClient.baseURLString + "/product-image?name=\(encoded)") else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let img = UIImage(data: data) else { return nil }
            try? data.write(to: cacheFile(for: key), options: .atomic)
            return img
        } catch {
            print("[ProductImageLoader] fetch failed for \(key): \(error)")
            return nil
        }
    }

    nonisolated private static func loadFromDisk(key: String) async -> UIImage? {
        let file = cacheFile(for: key)
        if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
            return img
        }
        return nil
    }

    /// Opens `?stream=1`. The server returns either a plain `image/png` (a cache
    /// hit — no streaming) or an SSE stream of `partial`/`complete` events whose
    /// `data:` payload is `{"b64_json": "..."}`. Partial frames are delivered via
    /// `onPartial`; the finished image is returned and written to disk.
    nonisolated private static func streamFromNetwork(
        key: String,
        onPartial: @escaping @Sendable (UIImage) -> Void
    ) async -> UIImage? {
        guard let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: APIClient.baseURLString + "/product-image?name=\(encoded)&stream=1") else { return nil }
        do {
            let (bytes, response) = try await URLSession.shared.bytes(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

            // Cache hit served as a plain PNG — no SSE to parse.
            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if contentType.hasPrefix("image/") {
                var data = Data()
                for try await b in bytes { data.append(b) }
                guard let img = UIImage(data: data) else { return nil }
                try? data.write(to: cacheFile(for: key), options: .atomic)
                return img
            }

            // SSE: accumulate `event:`/`data:` lines, dispatch on each blank line.
            var event = ""
            var dataBuf = ""
            var finalData: Data?

            func flushEvent() {
                guard let payload = decodeSSEImage(dataBuf) else {
                    event = ""
                    dataBuf = ""
                    return
                }
                if event == "partial", let img = UIImage(data: payload) {
                    onPartial(img)
                } else if event == "complete" {
                    finalData = payload
                }
                event = ""
                dataBuf = ""
            }

            for try await line in bytes.lines {
                let normalizedLine = line.trimmingCharacters(in: .newlines)
                if normalizedLine.isEmpty {
                    flushEvent()
                    continue
                }
                if normalizedLine.hasPrefix("event:") {
                    event = String(normalizedLine.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
                } else if normalizedLine.hasPrefix("data:") {
                    dataBuf += String(normalizedLine.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if !event.isEmpty || !dataBuf.isEmpty { flushEvent() }

            guard let finalData, let img = UIImage(data: finalData) else { return nil }
            try? finalData.write(to: cacheFile(for: key), options: .atomic)
            return img
        } catch {
            print("[ProductImageLoader] stream failed for \(key): \(error)")
            return nil
        }
    }

    /// Decodes an SSE `data:` JSON payload (`{"b64_json": "..."}`) into PNG bytes.
    nonisolated private static func decodeSSEImage(_ json: String) -> Data? {
        struct Frame: Decodable { let b64_json: String? }
        guard !json.isEmpty, let jsonData = json.data(using: .utf8),
              let frame = try? JSONDecoder().decode(Frame.self, from: jsonData),
              let b64 = frame.b64_json,
              let bytes = Data(base64Encoded: b64) else { return nil }
        return bytes
    }

    /// Directory where product images are persisted. Lives in Application
    /// Support rather than Caches so iOS won't purge it under storage pressure
    /// while the app is backgrounded — that durability is what lets already-loaded
    /// images appear when the device is offline. Excluded from iCloud backup
    /// since every image is re-fetchable from the server. Resolved once (static
    /// `let` initialization is thread-safe), which also runs the one-time
    /// migration below exactly once.
    nonisolated private static let cacheDirectory: URL = {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("ProductImages", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        // Re-downloadable images shouldn't bloat the user's iCloud backup.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)

        // Migrate images cached by older builds in the purgeable Caches
        // directory so users keep images they've already loaded.
        let legacy = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("product-images", isDirectory: true)
        if let files = try? fileManager.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) {
            for file in files {
                let dest = dir.appendingPathComponent(file.lastPathComponent)
                if !fileManager.fileExists(atPath: dest.path) {
                    try? fileManager.moveItem(at: file, to: dest)
                }
            }
            try? fileManager.removeItem(at: legacy)
        }
        return dir
    }()

    nonisolated private static func cacheFile(for name: String) -> URL {
        let safe = name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        return cacheDirectory.appendingPathComponent("\(safe).png")
    }
}

/// SwiftUI view that loads and displays a product image with a skeleton shimmer
/// while loading.
struct ProductImageView: View {
    let itemName: String
    var size: CGFloat = 48

    @State private var image: UIImage?
    @State private var isLoading = true

    private var imageKey: String {
        itemName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .transition(.opacity.animation(.easeIn(duration: 0.2)))
            } else if isLoading {
                ShimmerRect(cornerRadius: 10)
                    .frame(width: size, height: size)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.systemGray6))
                    .frame(width: size, height: size)
                    .overlay {
                        Image(systemName: "basket.fill")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: size * 0.35))
                    }
            }
        }
        .task(id: imageKey) {
            image = nil
            isLoading = true
            for await frame in ProductImageLoader.shared.imageStream(for: itemName) {
                withAnimation(.easeIn(duration: 0.2)) { image = frame.image }
                isLoading = !frame.isFinal
            }
            isLoading = false
        }
    }
}

// MARK: - Reusable shimmer primitives

/// A rounded-rect skeleton block with a sweeping shimmer gradient.
struct ShimmerRect: View {
    var cornerRadius: CGFloat = 8
    @State private var phase: CGFloat = -1.5

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(.systemGray5))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.4), .clear],
                            startPoint: UnitPoint(x: phase, y: 0.5),
                            endPoint: UnitPoint(x: phase + 1, y: 0.5)
                        )
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 1.5
                }
            }
    }
}

/// A circular skeleton block with a sweeping shimmer.
struct ShimmerCircle: View {
    @State private var phase: CGFloat = -1.5

    var body: some View {
        Circle()
            .fill(Color(.systemGray5))
            .overlay {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.4), .clear],
                            startPoint: UnitPoint(x: phase, y: 0.5),
                            endPoint: UnitPoint(x: phase + 1, y: 0.5)
                        )
                    )
            }
            .clipShape(Circle())
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 1.5
                }
            }
    }
}
