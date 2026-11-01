import Foundation
import CoreLocation

final class Positions {
    private var sources: [String: PositionSource] = [:]
    private var cached: CachedPosition?
    private let manager = CLLocationManager()
    func request(id: String, options: TrackingJSON, watch: Bool, completion: @escaping (Result<CLLocation, Error>) -> Void) {
        guard LocationServices.shared.isReady else {
            LocationServices.shared.whenReady { self.request(id: id, options: options, watch: watch, completion: completion) }
            return
        }
        if !watch && !LocationServices.shared.enabled { completion(.failure(TrackingError("LOCATION_DISABLED", "Location Services are disabled"))); return }
        if LocationServices.shared.enabled && manager.authorizationStatus != .authorizedAlways && manager.authorizationStatus != .authorizedWhenInUse { completion(.failure(TrackingError("PERMISSION_DENIED", "Location permission is required"))); return }
        if !watch, options.number("maximumAge") > 0, let cached, cached.age() <= options.number("maximumAge"), !(options.flag("_rejectMock") && cached.fix.sourceInformation?.isSimulatedBySoftware == true) { completion(.success(cached.fix)); return }
        let source = PositionSource(options: options, continuous: watch) { [weak self] result in
            if case .success(let fix) = result { self?.cached = CachedPosition(fix) }
            if !watch { self?.sources.removeValue(forKey: id) }
            else if case .failure = result { self?.sources.removeValue(forKey: id) }
            completion(result)
        }
        sources[id] = source
        source.start()
    }
    func clear(_ id: String) { sources.removeValue(forKey: id)?.stop() }
}
