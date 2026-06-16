import CloudKit
import Foundation
import Sentry

/// Reports CloudKit production/development schema mismatches to Sentry so missing
/// or outdated record fields surface quickly in error tracking.
enum CloudKitSchemaTelemetry {
    struct Mismatch: Equatable, Sendable {
        let recordType: String
        let fieldName: String
        let environment: String?
    }

    /// Parses CK "Cannot create or modify field … in record …" schema errors.
    static func parseMismatch(from error: Error) -> Mismatch? {
        guard let ck = error as? CKError, ck.code == .invalidArguments else { return nil }
        for message in errorMessages(from: ck) {
            if let mismatch = parseMismatchMessage(message) {
                return mismatch
            }
        }
        return nil
    }

    /// Sends a grouped warning to Sentry. Deduplicated per app session by record
    /// type + field + environment (+ recovery outcome for failures).
    static func report(
        mismatch: Mismatch,
        error: Error,
        context: String,
        recordName: String? = nil,
        recovered: Bool
    ) {
        let environment = mismatch.environment ?? "unknown"
        let fingerprintKey = "\(mismatch.recordType)|\(mismatch.fieldName)|\(environment)|recovered=\(recovered)"
        guard markReported(fingerprintKey) else { return }

        let event = Event(level: recovered ? .warning : .error)
        event.message = SentryMessage(
            formatted: "CloudKit schema mismatch: \(mismatch.recordType).\(mismatch.fieldName)"
        )
        event.fingerprint = [
            "cloudkit-schema-mismatch",
            mismatch.recordType,
            mismatch.fieldName,
            environment,
            recovered ? "recovered" : "unrecovered",
        ]
        event.tags = [
            "cloudkit.record_type": mismatch.recordType,
            "cloudkit.field": mismatch.fieldName,
            "cloudkit.schema_environment": environment,
            "cloudkit.recovered": recovered ? "yes" : "no",
            "cloudkit.context": context,
        ]
        var extra: [String: Any] = [
            "context": context,
            "recovered": recovered,
            "error_summary": shortError(error),
        ]
        if let recordName, !recordName.isEmpty {
            extra["record_name"] = recordName
        }
        event.extra = extra

        SentrySDK.capture(event: event)

        #if DEBUG
        print("[CloudKitSchema] reported to Sentry — \(mismatch.recordType).\(mismatch.fieldName) (\(context), recovered=\(recovered))")
        #endif
    }

    // MARK: - Private

    private static var reportedFingerprintKeys: Set<String> = []
    private static let lock = NSLock()

    private static func markReported(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return reportedFingerprintKeys.insert(key).inserted
    }

    private static func errorMessages(from error: CKError) -> [String] {
        var messages = [error.localizedDescription]
        for value in error.errorUserInfo.values {
            if let text = value as? String {
                messages.append(text)
            } else if let nested = value as? NSError {
                messages.append(nested.localizedDescription)
            }
        }
        return messages
    }

    /// Matches CloudKit Console messages such as:
    /// `Cannot create or modify field 'replacementItemName' in record 'ShoppingTripItem' in production schema`
    private static func parseMismatchMessage(_ message: String) -> Mismatch? {
        guard message.localizedCaseInsensitiveContains("cannot create or modify field") else {
            return nil
        }

        let fieldPattern = #"field\s+'([^']+)'"#
        let recordPattern = #"record\s+'([^']+)'"#
        let environmentPattern = #"in\s+(production|development)\s+schema"#

        guard
            let fieldName = firstCapture(in: message, pattern: fieldPattern),
            let recordType = firstCapture(in: message, pattern: recordPattern)
        else {
            return nil
        }

        let environment = firstCapture(in: message, pattern: environmentPattern)
        return Mismatch(recordType: recordType, fieldName: fieldName, environment: environment)
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard
            let match = regex.firstMatch(in: text, options: [], range: range),
            match.numberOfRanges > 1,
            let captureRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[captureRange])
    }

    private static func shortError(_ error: Error) -> String {
        if let ck = error as? CKError {
            return "CKError.\(ck.code.rawValue): \(ck.localizedDescription)"
        }
        return error.localizedDescription
    }
}

#if DEBUG
extension CloudKitSchemaTelemetry {
    static func _resetReportedFingerprintsForTesting() {
        lock.lock()
        reportedFingerprintKeys.removeAll()
        lock.unlock()
    }
}
#endif
