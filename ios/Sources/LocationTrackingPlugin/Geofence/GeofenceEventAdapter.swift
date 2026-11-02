import Foundation

enum MonitorState: Equatable { case unknown, satisfied, unsatisfied, unmonitored }

struct MonitorFailure: Equatable {
    var id: String
    var code: String
    var message: String
}

final class GeofenceEventAdapter {
    private var known: [String: MonitorState] = [:]
    private var initialTrigger: [String: Bool] = [:]
    private var reported: [String: Set<String>] = [:]

    func seed(_ id: String, _ state: MonitorState) {
        if known[id] == nil { known[id] = state }
    }

    func registered(_ id: String, initialTriggerEntry: Bool) {
        known[id] = .unknown
        initialTrigger[id] = initialTriggerEntry
        reported[id] = nil
    }

    func removed(_ id: String) {
        known[id] = nil; initialTrigger[id] = nil; reported[id] = nil
    }

    func retain(_ ids: Set<String>) {
        known = known.filter { ids.contains($0.key) }
        initialTrigger = initialTrigger.filter { ids.contains($0.key) }
        reported = reported.filter { ids.contains($0.key) }
    }

    func handle(_ id: String, _ state: MonitorState, failures diagnostics: [(String, String)]) -> ([OsGeofenceTransition], [MonitorFailure]) {
        var failures: [MonitorFailure] = []
        for (code, message) in diagnostics where !(reported[id]?.contains(code) ?? false) {
            reported[id, default: []].insert(code)
            failures.append(MonitorFailure(id: id, code: code, message: "geofence '\(id)': " + message))
        }
        guard diagnostics.isEmpty, state == .satisfied || state == .unsatisfied, let previous = known[id] else { return ([], failures) }
        reported[id] = nil
        guard previous != state else { return ([], failures) }
        known[id] = state
        if previous == .unknown || previous == .unmonitored {
            if state == .satisfied { return (initialTrigger[id] ?? true ? [OsGeofenceTransition(id: id, action: .enter, location: nil)] : [], failures) }
            return ([OsGeofenceTransition(id: id, action: .exit, location: nil, initial: true)], failures)
        }
        return ([OsGeofenceTransition(id: id, action: state == .satisfied ? .enter : .exit, location: nil)], failures)
    }
}
