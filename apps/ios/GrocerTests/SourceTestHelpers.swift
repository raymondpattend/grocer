import Foundation
import XCTest

enum SourceTestError: Error, CustomStringConvertible {
    case missingMarker(String)

    var description: String {
        switch self {
        case .missingMarker(let marker):
            return "Missing source marker: \(marker)"
        }
    }
}

func iosRootURL(filePath: String = #filePath) -> URL {
    URL(fileURLWithPath: filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

func source(_ relativePath: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
    let url = iosRootURL().appendingPathComponent(relativePath)
    do {
        return try String(contentsOf: url, encoding: .utf8)
    } catch {
        XCTFail("Could not read \(url.path): \(error)", file: file, line: line)
        throw error
    }
}

func excerpt(
    _ source: String,
    from startMarker: String,
    to endMarker: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> String {
    guard let start = source.range(of: startMarker) else {
        XCTFail("Missing source marker: \(startMarker)", file: file, line: line)
        throw SourceTestError.missingMarker(startMarker)
    }
    guard let end = source.range(of: endMarker, range: start.upperBound..<source.endIndex) else {
        XCTFail("Missing source marker: \(endMarker)", file: file, line: line)
        throw SourceTestError.missingMarker(endMarker)
    }
    return String(source[start.lowerBound..<end.lowerBound])
}

func sourceIndex(
    of needle: String,
    in source: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> String.Index {
    guard let index = source.range(of: needle)?.lowerBound else {
        XCTFail("Missing source marker: \(needle)", file: file, line: line)
        throw SourceTestError.missingMarker(needle)
    }
    return index
}

func hasUncommentedLine(containing needle: String, in relativePath: String) throws -> Bool {
    let source = try source(relativePath)
    return source.split(separator: "\n").contains { line in
        line.contains(needle) && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }
}
