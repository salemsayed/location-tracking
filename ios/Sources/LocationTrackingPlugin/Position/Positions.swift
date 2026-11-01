import Foundation
import CoreLocation

final class Positions {
    private var sources: [String: PositionSource] = [:]
    private var cached: CLLocation?
    func request(id: String, options: TrackingJSON, watch: Bool, completion: @escaping (Result<CLLocation, Error>) -> Void) {
        if !watch, options.number("maximumAge") > 0, let cached, Date().timeIntervalSince(cached.timestamp) * 1000 <= options.number("maximumAge") { completion(.success(cached)); return }
        let source = PositionSource(options: options, continuous: watch) { [weak self] result in
            if case .success(let fix) = result { self?.cached = fix }
            if !watch { self?.sources.removeValue(forKey: id) }
            completion(result)
        }
        sources[id] = source
        source.start()
    }
    func clear(_ id: String) { sources.removeValue(forKey: id)?.stop() }
}
