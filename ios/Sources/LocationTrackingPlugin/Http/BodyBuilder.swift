import Foundation

struct BodyBuilder {
    static func build(_ records: [TrackingJSON], http: TrackingJSON, sentAt: String = iso()) throws -> Data {
        let rendered = records.map { record -> Any in
            var wire = record
            wire["sent_at"] = sentAt
            let template = record.text("event") == "geofence" ? http.text("geofenceTemplate", http.text("locationTemplate")) : http.text("locationTemplate")
            return render(template, record: wire) ?? wire
        }
        let root = http.text("rootProperty", "location")
        let merge = root == "." || root.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let batch = http.flag("batchSync")
        if merge && batch { return try jsonData(rendered) }
        let value: Any = batch ? rendered : rendered[0]
        var body: TrackingJSON
        if merge {
            guard let object = value as? TrackingJSON else { return try jsonData(value) }
            body = object
        } else { body = [root: value] }
        for (key, value) in http.object("params") where body[key] == nil { body[key] = value }
        return try jsonData(body)
    }
    static func render(_ template: String, record: TrackingJSON) -> Any? {
        guard !template.isEmpty else { return nil }
        let regex = try! NSRegularExpression(pattern: "(\"?)<%=\\s*(.*?)\\s*%>(\"?)", options: .dotMatchesLineSeparators)
        let source = template as NSString
        var output = template
        for match in regex.matches(in: template, range: NSRange(location: 0, length: source.length)).reversed() {
            let key = source.substring(with: match.range(at: 2))
            let open = source.substring(with: match.range(at: 1))
            let close = source.substring(with: match.range(at: 3))
            let coordinateKeys = ["latitude", "longitude", "accuracy", "altitude", "altitude_accuracy", "speed", "speed_accuracy", "heading", "heading_accuracy"]
            let path = coordinateKeys.contains(key) ? "coords." + key : key
            var value: Any? = key == "record" ? record : record
            if key != "record" {
                for component in path.split(separator: ".") { value = (value as? TrackingJSON)?[String(component)] }
            }
            if key == "extras", value == nil { value = TrackingJSON() }
            let supportedRoots = Set(["uuid", "event", "timestamp", "recorded_at", "sent_at", "coords", "is_moving", "odometer", "mock", "activity", "battery", "network", "device", "elapsed_realtime_ms", "boot_count", "backend", "reason", "stopped_at", "geofence", "provider", "extras", "record"])
            let replacement: String
            if !supportedRoots.contains(String(path.split(separator: ".")[0])) { replacement = open + close }
            else if value == nil || value is NSNull { replacement = open.isEmpty || close.isEmpty ? open + "null" + close : "null" }
            else if let data = try? jsonData(value!), let literal = String(data: data, encoding: .utf8) {
                replacement = open + (value is String ? String(literal.dropFirst().dropLast()) : literal) + close
            } else { replacement = "null" }
            if let range = Range(match.range, in: output) { output.replaceSubrange(range, with: replacement) }
        }
        guard let data = output.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data), value is TrackingJSON || value is [Any] else { return nil }
        return value
    }
}
