import Foundation
import CoreLocation

final class PositionSource: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let callback: (Result<CLLocation, Error>) -> Void
    private let samples: Int
    private let continuous: Bool
    private let interval: TimeInterval
    private var accepted = 0
    private var best: CLLocation?
    private var stopped = false
    private var timeout: DispatchWorkItem?
    private var deliveredAt = Date.distantPast
    init(options: TrackingJSON, continuous: Bool, callback: @escaping (Result<CLLocation, Error>) -> Void) {
        self.callback = callback
        self.samples = max(1, Int(options.number("samples", 3)))
        self.continuous = continuous
        self.interval = max(0, options.number("interval", 1000)) / 1000
        super.init()
        manager.delegate = self
        switch options.text("desiredAccuracy", "high") {
        case "balanced": manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        case "low": manager.desiredAccuracy = kCLLocationAccuracyKilometer
        case "passive": manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        default: manager.desiredAccuracy = kCLLocationAccuracyBest
        }
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        manager.allowsBackgroundLocationUpdates = continuous && modes.contains("location")
        manager.showsBackgroundLocationIndicator = continuous
        if !continuous {
            let item = DispatchWorkItem { [weak self] in
                guard let self, !self.stopped else { return }
                if let best = self.best { self.callback(.success(best)) }
                else { self.callback(.failure(TrackingError("TIMEOUT", "Position request timed out"))) }
                self.stop()
            }
            timeout = item
            DispatchQueue.main.asyncAfter(deadline: .now() + options.number("timeout", 30000) / 1000, execute: item)
        }
    }
    func start() {
        guard CLLocationManager.locationServicesEnabled() else { callback(.failure(TrackingError("LOCATION_DISABLED", "Location Services are disabled"))); stop(); return }
        guard manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse else { callback(.failure(TrackingError("PERMISSION_DENIED", "Location permission is required"))); stop(); return }
        manager.startUpdatingLocation()
    }
    func stop() { stopped = true; timeout?.cancel(); manager.stopUpdatingLocation(); manager.delegate = nil }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !stopped else { return }
        for fix in locations where fix.horizontalAccuracy >= 0 && CLLocationCoordinate2DIsValid(fix.coordinate) {
            if continuous {
                if Date().timeIntervalSince(deliveredAt) >= interval { deliveredAt = Date(); callback(.success(fix)) }
            } else {
                if best == nil || fix.horizontalAccuracy < best!.horizontalAccuracy { best = fix }
                accepted += 1
                if accepted >= samples { callback(.success(best!)); stop(); return }
            }
        }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .locationUnknown { return }
        guard !stopped else { return }
        callback(.failure(TrackingError((error as? CLError)?.code == .denied ? "PERMISSION_DENIED" : "UNAVAILABLE", "Core Location could not obtain a position")))
        if !continuous { stop() }
    }
}
