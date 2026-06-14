import Foundation

/// In-memory capture of everything the app writes to `stdout`/`stderr`.
///
/// The codebase logs diagnostics with plain `print(...)` (e.g. the `[CK]`,
/// `[RevenueCat]`, `[Notifications]` traces). To make those visible inside the
/// app — and exportable from the shake-to-debug screen — we redirect the
/// process's stdout/stderr through a pipe, tee a copy into a ring buffer, and
/// forward the original bytes back to the real console so Xcode keeps showing
/// logs as usual.
///
/// Capturing is best-effort: if the redirect can't be installed the app behaves
/// exactly as before, just without an in-app log feed.
final class LogStore {
    static let shared = LogStore()

    /// Most recent lines, oldest first. Capped to `maxLines`.
    private var lines: [String] = []
    private let maxLines = 4000
    /// Partial trailing chunk not yet terminated by a newline.
    private var partial = ""

    private let lock = NSLock()
    private var started = false

    private var pipe: Pipe?
    private var originalStdout: Int32 = -1
    private var originalStderr: Int32 = -1

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private init() {}

    // MARK: - Capture

    /// Begins redirecting stdout/stderr into the ring buffer. Idempotent and safe
    /// to call once, as early as possible at launch.
    func startCapturing() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()

        appendLine("=== Grocer log session started \(ISO8601DateFormatter().string(from: Date())) ===")

        let pipe = Pipe()
        self.pipe = pipe

        // Keep handles to the real console so we can echo through to Xcode.
        originalStdout = dup(STDOUT_FILENO)
        originalStderr = dup(STDERR_FILENO)

        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }

            // Forward to the real console first so nothing is lost.
            if self.originalStdout != -1 {
                data.withUnsafeBytes { raw in
                    _ = write(self.originalStdout, raw.baseAddress, data.count)
                }
            }

            if let text = String(data: data, encoding: .utf8) {
                self.ingest(text)
            }
        }
    }

    private func ingest(_ text: String) {
        lock.lock()
        defer { lock.unlock() }

        var buffer = partial + text
        partial = ""

        // Split into complete lines; stash any trailing partial fragment.
        while let newlineIndex = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newlineIndex])
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            store(line)
        }
        partial = buffer
    }

    /// Adds an explicit line to the log (also captured if it later prints).
    func appendLine(_ line: String) {
        lock.lock()
        store(line)
        lock.unlock()
    }

    /// Caller must hold `lock`.
    private func store(_ line: String) {
        let stamped = "\(Self.timestampFormatter.string(from: Date()))  \(line)"
        lines.append(stamped)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    // MARK: - Read

    /// Current captured lines, oldest first.
    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var result = lines
        if !partial.isEmpty {
            result.append("\(Self.timestampFormatter.string(from: Date()))  \(partial)")
        }
        return result
    }

    func text() -> String {
        snapshot().joined(separator: "\n")
    }

    func clear() {
        lock.lock()
        lines.removeAll()
        partial = ""
        lock.unlock()
        appendLine("=== Logs cleared \(ISO8601DateFormatter().string(from: Date())) ===")
    }
}
