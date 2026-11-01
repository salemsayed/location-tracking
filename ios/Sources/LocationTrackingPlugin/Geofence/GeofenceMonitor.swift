import Foundation
import CoreLocation

@available(iOS 17.0, *)
final class GeofenceMonitor: GeofenceBackend, @unchecked Sendable {
    static let name = "BricksSoftLocationTrackingGeofences"
    private static var instance: GeofenceMonitor?
    static func shared(queue: DispatchQueue) -> GeofenceMonitor {
        if let instance { return instance }
        let created = GeofenceMonitor(queue: queue)
        instance = created
        return created
    }
    private let queue: DispatchQueue
    private var tail: Task<Void, Never>?
    private var monitor: Task<CLMonitor, Never>
    private var initial: [String: Double] = [:]
    private var session: AnyObject?
    var transitions: (([OsGeofenceTransition]) -> Void)?
    var diagnostic: ((String, String) -> Void)?

    private init(queue: DispatchQueue) {
        self.queue = queue
        monitor = Task { await CLMonitor(Self.name) }
        let opened = monitor
        Task { [weak self] in
            let monitor = await opened.value
            do {
                for try await event in await monitor.events {
                    let id = event.identifier, state = event.state, limited: Bool
                    if #available(iOS 18.0, *) { limited = event.accuracyLimited || event.conditionLimitExceeded } else { limited = false }
                    self?.queue.async { self?.handle(id, state, limited: limited) }
                }
            } catch {
                self?.queue.async { self?.diagnostic?("error", "Geofence monitor events ended") }
            }
        }
    }

    private func enqueue(_ operation: @escaping (CLMonitor) async -> Void) {
        let previous = tail, opened = monitor
        tail = Task {
            await previous?.value
            await operation(await opened.value)
        }
    }

    private func handle(_ id: String, _ state: CLMonitor.Event.State, limited: Bool) {
        if limited { diagnostic?("warn", "Geofence '\(id)' events are limited by Core Location") }
        if let added = initial.removeValue(forKey: id), Self.wall() - added <= GeofenceManager.initialTriggerWindow { return }
        switch state {
        case .satisfied: transitions?([OsGeofenceTransition(id: id, action: .enter, location: nil)])
        case .unsatisfied: transitions?([OsGeofenceTransition(id: id, action: .exit, location: nil)])
        default: break
        }
    }

    func add(_ regions: [OsGeofence]) {
        let time = Self.wall()
        for region in regions {
            if region.initialTriggerEntry { initial.removeValue(forKey: region.id) } else { initial[region.id] = time }
            let condition = CLMonitor.CircularGeographicCondition(center: CLLocationCoordinate2D(latitude: region.latitude, longitude: region.longitude), radius: region.radius)
            let assumed: CLMonitor.Event.State = region.initialTriggerEntry ? .unsatisfied : .unknown
            enqueue { await $0.add(condition, identifier: region.id, assuming: assumed) }
        }
    }

    func remove(_ ids: [String]) {
        for id in ids {
            initial.removeValue(forKey: id)
            enqueue { await $0.remove(id) }
        }
    }

    func retain(_ ids: Set<String>) {
        initial = initial.filter { ids.contains($0.key) }
        enqueue { monitor in
            for id in await monitor.identifiers where !ids.contains(id) { await monitor.remove(id) }
        }
    }

    private static func wall() -> Double { Date().timeIntervalSince1970 * 1000 }

    func holdSession(_ always: Bool) {
        guard #available(iOS 18.0, *) else { return }
        if always { if session == nil { session = CLServiceSession(authorization: .always) } }
        else { (session as? CLServiceSession)?.invalidate(); session = nil }
    }
}
