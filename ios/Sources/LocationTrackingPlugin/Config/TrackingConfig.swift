import Foundation

final class TrackingConfig {
    private(set) var value: TrackingJSON
    private let store: TrackingStore
    private let secrets: SecretStore
    init(store: TrackingStore, secrets: SecretStore) throws {
        self.store = store
        self.secrets = secrets
        value = Self.merge(ConfigDefaults.value, try store.load("config") ?? [:])
        if let auth = try secrets.load() {
            var http = value.object("http")
            http["authorization"] = auth
            value["http"] = http
        }
    }
    static func merge(_ old: TrackingJSON, _ patch: TrackingJSON, path: String = "") -> TrackingJSON {
        let maps = ["http.headers", "http.params", "persistence.extras", "http.authorization.refreshPayload", "http.authorization.refreshHeaders"]
        var result = old
        for (key, new) in patch {
            let next = path.isEmpty ? key : path + "." + key
            if let object = new as? TrackingJSON, !maps.contains(next) {
                result[key] = merge(old.object(key), object, path: next)
            } else if let masked = new as? String, masked.hasPrefix("***"), let stored = old[key] {
                result[key] = stored
            } else { result[key] = new }
        }
        return result
    }
    @discardableResult func apply(_ patch: TrackingJSON, reset: Bool) throws -> [String] {
        var candidate = Self.merge(reset ? ConfigDefaults.value : value, patch)
        var warnings: [String] = []
        var heartbeat = candidate.object("heartbeat")
        heartbeat["minInterval"] = max(60, heartbeat.number("minInterval", 180))
        heartbeat["maxInterval"] = max(heartbeat.number("minInterval"), heartbeat.number("maxInterval", 300))
        heartbeat["uploadKeepAwake"] = min(60, max(0, heartbeat.number("uploadKeepAwake", 10)))
        candidate["heartbeat"] = heartbeat
        var notification = candidate.object("notification")
        var resume = notification.object("resume")
        if resume.number("delay", 600) < heartbeat.number("maxInterval") + 60 {
            resume["delay"] = heartbeat.number("maxInterval") + 60
            warnings.append("notification.resume.delay raised to heartbeat.maxInterval + 60")
        }
        notification["resume"] = resume
        candidate["notification"] = notification
        let http = candidate.object("http")
        if let url = http["url"] as? String, !url.isEmpty {
            guard let parsed = URL(string: url), ["https", "http"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil else { throw TrackingError("INVALID_ARGUMENT", "http.url must be an HTTP URL") }
            if parsed.scheme == "http" { warnings.append("http.url uses unencrypted HTTP; iOS App Transport Security may refuse it") }
        }
        guard ["POST", "PUT", "PATCH"].contains(http.text("method", "POST")), http.number("timeout", 60000) > 0, http.number("maxBatchSize", 100) >= 1 else { throw TrackingError("INVALID_ARGUMENT", "Invalid HTTP method, timeout or batch size") }
        _ = try jsonData(candidate)
        var persisted = candidate
        var persistedHttp = http
        persistedHttp["authorization"] = NSNull()
        persisted["http"] = persistedHttp
        try secrets.save(http["authorization"] as? TrackingJSON)
        try store.save("config", persisted)
        value = candidate
        return warnings
    }
    var masked: TrackingJSON {
        var result = value
        var http = result.object("http")
        if var auth = http["authorization"] as? TrackingJSON {
            for key in ["accessToken", "refreshToken"] {
                if let text = auth[key] as? String { auth[key] = Self.mask(text) }
            }
            for key in ["refreshPayload", "refreshHeaders"] {
                var map = auth.object(key)
                for (name, value) in map {
                    if let text = value as? String, !text.contains("{refreshToken}") { map[name] = Self.mask(text) }
                }
                auth[key] = map
            }
            http["authorization"] = auth
        }
        result["http"] = http
        return result
    }
    private static func mask(_ text: String) -> String { text.count > 8 ? "***" + text.suffix(4) : "***" }
}
