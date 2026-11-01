import Foundation
import os

final class TrackingLog {
    private let logger = Logger(subsystem: "com.brickssoft.locationtracking", category: "plugin")
    private var entries: [TrackingJSON] = []
    func write(_ level: String, _ message: String) {
        let safe = Self.redact(message)
        entries.append(["at": Date().timeIntervalSince1970 * 1000, "level": level, "text": "\(iso()) \(level) \(safe)"])
        if entries.count > 2000 { entries.removeFirst(entries.count - 2000) }
        logger.log("\(safe, privacy: .private)")
    }
    func read(_ query: TrackingJSON) -> String {
        var values = entries.filter { $0.number("at") >= query.number("start", 0) && $0.number("at") <= query.number("end", .greatestFiniteMagnitude) && (query.text("level").isEmpty || $0.text("level") == query.text("level")) }
        if query.text("order", "asc") == "desc" { values.reverse() }
        return values.prefix(max(0, Int(query.number("limit", 2000)))).map { $0.text("text") }.joined(separator: "\n")
    }
    func clear() { entries = [] }
    static func redact(_ text: String) -> String {
        var result = text
        for pattern in ["(?i)Bearer\\s+[^\\s,;\"}]+", "(?i)(accessToken|refreshToken|authorization|password|secret)[\\s\"']*[:=][\\s\"']*[^\\s,;\"}]+"] {
            if let regex = try? NSRegularExpression(pattern: pattern) { result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "[redacted]") }
        }
        return result
    }
}
