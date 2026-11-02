import Foundation
import CoreLocation

@available(iOS 17.0, *)
final class GeofenceMonitor: GeofenceBackend, @unchecked Sendable {
    static let defaultName = "BricksSoftLocationTrackingGeofences"
    private static var instance: GeofenceMonitor?
    static func shared(queue: DispatchQueue, authorization: @escaping () -> CLAuthorizationStatus) -> GeofenceMonitor {
        if let instance { return instance }
        let created = GeofenceMonitor(name: defaultName, queue: queue, authorization: authorization)
        instance = created
        return created
    }
    private let name: String
    private let queue: DispatchQueue
    private let authorization: () -> CLAuthorizationStatus
    private var monitor: Task<CLMonitor, Never>?
    private var tail: Task<Void, Never>?
    private var session: AnyObject?
    let adapter = GeofenceEventAdapter()
    var transitions: (([OsGeofenceTransition]) -> Void)?
    var failures: (([MonitorFailure]) -> Void)?
    var isOpen: Bool { monitor != nil }

    init(name: String, queue: DispatchQueue, authorization: @escaping () -> CLAuthorizationStatus) {
        self.name = name; self.queue = queue; self.authorization = authorization
    }

    private func open() -> Task<CLMonitor, Never>? {
        if let monitor { return monitor }
        guard authorization() != .notDetermined else { return nil }
        let name = self.name
        let opened = Task { await CLMonitor(name) }
        monitor = opened
        Task { [weak self] in
            let monitor = await opened.value
            var persisted: [(String, MonitorState)] = []
            for id in await monitor.identifiers { if let record = await monitor.record(for: id) { persisted.append((id, Self.state(record.lastEvent.state))) } }
            self?.queue.async { persisted.forEach { self?.adapter.seed($0.0, $0.1) } }
            do {
                for try await event in await monitor.events {
                    let id = event.identifier, state = Self.state(event.state), diagnostics = Self.diagnostics(event)
                    self?.queue.async { self?.handle(id, state, diagnostics) }
                }
            } catch {
                self?.queue.async { self?.failures?([MonitorFailure(id: "", code: "UNAVAILABLE", message: "geofence monitoring stopped: " + error.localizedDescription)]) }
            }
        }
        return opened
    }

    private func handle(_ id: String, _ state: MonitorState, _ diagnostics: [(String, String)]) {
        let (transitions, failures) = adapter.handle(id, state, failures: diagnostics)
        if !failures.isEmpty { self.failures?(failures) }
        if !transitions.isEmpty { self.transitions?(transitions) }
    }

    private func enqueue(_ operation: @escaping (CLMonitor) async -> Void) {
        guard let opened = open() else { return }
        let previous = tail
        tail = Task {
            await previous?.value
            await operation(await opened.value)
        }
    }

    func add(_ regions: [OsGeofence]) {
        guard open() != nil else { return }
        for region in regions {
            adapter.registered(region.id, initialTriggerEntry: region.initialTriggerEntry)
            let condition = CLMonitor.CircularGeographicCondition(center: CLLocationCoordinate2D(latitude: region.latitude, longitude: region.longitude), radius: region.radius)
            enqueue { await $0.add(condition, identifier: region.id, assuming: .unknown) }
        }
    }

    func remove(_ ids: [String]) {
        for id in ids {
            adapter.removed(id)
            enqueue { await $0.remove(id) }
        }
    }

    func retain(_ ids: Set<String>) {
        adapter.retain(ids)
        enqueue { monitor in
            for id in await monitor.identifiers where !ids.contains(id) { await monitor.remove(id) }
        }
    }

    func holdSession(_ always: Bool) {
        guard #available(iOS 18.0, *) else { return }
        if always { if session == nil { session = CLServiceSession(authorization: .always) } }
        else { (session as? CLServiceSession)?.invalidate(); session = nil }
    }

    private static func state(_ value: CLMonitor.Event.State) -> MonitorState {
        switch value {
        case .satisfied: return .satisfied
        case .unsatisfied: return .unsatisfied
        case .unknown: return .unknown
        default: return .unmonitored
        }
    }

    private static func diagnostics(_ event: CLMonitor.Event) -> [(String, String)] {
        guard #available(iOS 18.0, *) else { return [] }
        var result: [(String, String)] = []
        if event.conditionLimitExceeded { result.append(("TOO_MANY_GEOFENCES", "Core Location suspended monitoring because the app monitors too many conditions")) }
        if event.accuracyLimited { result.append(("PERMISSION_DENIED", "Core Location suspended monitoring while location accuracy is approximate")) }
        if event.authorizationDeniedGlobally { result.append(("LOCATION_DISABLED", "Core Location suspended monitoring while Location Services are off")) }
        else if event.authorizationDenied || event.authorizationRestricted { result.append(("PERMISSION_DENIED", "Core Location suspended monitoring because location authorization is denied")) }
        if event.conditionUnsupported { result.append(("UNAVAILABLE", "Core Location does not support monitoring this condition")) }
        if event.persistenceUnavailable { result.append(("IO_ERROR", "Core Location could not store the monitored condition")) }
        if event.serviceSessionRequired { result.append(("UNAVAILABLE", "Core Location requires a service session for this app")) }
        return result
    }
}
