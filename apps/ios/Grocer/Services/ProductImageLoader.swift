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

    // MARK: - Off-main-thread loading

    nonisolated private static func load(key: String) async -> UIImage? {
        let file = cacheFile(for: key)

        // Disk cache (read + decode off the main thread).
        if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
            return img
        }

        // Network fetch.
        guard let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: APIClient.baseURLString + "/product-image?name=\(encoded)") else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let img = UIImage(data: data) else { return nil }
            try? data.write(to: file, options: .atomic)
            return img
        } catch {
            print("[ProductImageLoader] fetch failed for \(key): \(error)")
            return nil
        }
    }

    nonisolated private static func cacheFile(for name: String) -> URL {
        let fileManager = FileManager.default
        let dir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("product-images", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        return dir.appendingPathComponent("\(safe).png")
    }
}

/// SwiftUI view that loads and displays a product image with a skeleton shimmer
/// while loading.
struct ProductImageView: View {
    let itemName: String
    var size: CGFloat = 48

    @State private var image: UIImage?
    @State private var isLoading = true

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
        .task {
            let loader = ProductImageLoader.shared
            image = await loader.image(for: itemName)
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
