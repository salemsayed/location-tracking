import Foundation
import CoreLocation
import CoreMotion
import UIKit

struct RouteProfile: Equatable {
    var enabled: Bool
    var moving: Bool
    var accuracy: String
    var activityEnabled: Bool
    var sessionID = ""
}

final class RouteSource: NSObject, CLLocationManagerDelegate {
    private let manager: CLLocationManager
    private let relaunch: CLLocationManager
    private let motion = CMMotionActivityManager()
    private var profile = RouteProfile(enabled: false, moving: false, accuracy: "high", activityEnabled: false)
    private var activityRunning = false
    private var cachedLocation: TrackedLocation?
    var locations: (([TrackedLocation], String) -> Void)?
    var error: ((TrackingError, String) -> Void)?
    var activity: ((ActivitySample, String) -> Void)?
    var authorizationChanged: (() -> Void)?
    var lastLocation: TrackedLocation? {
        precondition(Thread.isMainThread)
        return cachedLocation
    }
    init(manager: CLLocationManager = CLLocationManager(), relaunch: CLLocationManager = CLLocationManager()) {
        self.manager = manager; self.relaunch = relaunch
        super.init()
        manager.delegate = self; relaunch.delegate = self
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
    }
    func apply(_ new: RouteProfile, force: Bool = false) {
        precondition(Thread.isMainThread)
        guard new != profile || force else { return }
        if new.sessionID != profile.sessionID { stopMotion() }
        profile = new
        guard new.enabled else { manager.stopUpdatingLocation(); relaunch.stopMonitoringSignificantLocationChanges(); stopMotion(); return }
        guard manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse else {
            manager.stopUpdatingLocation(); relaunch.stopMonitoringSignificantLocationChanges(); stopMotion(); return
        }
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        manager.allowsBackgroundLocationUpdates = modes.contains("location")
        manager.desiredAccuracy = new.moving ? Self.accuracy(new.accuracy) : kCLLocationAccuracyHundredMeters
        if force { manager.stopUpdatingLocation() }
        manager.startUpdatingLocation()
        if manager.authorizationStatus == .authorizedAlways && CLLocationManager.significantLocationChangeMonitoringAvailable() { relaunch.startMonitoringSignificantLocationChanges() }
        else { relaunch.stopMonitoringSignificantLocationChanges() }
        if new.activityEnabled && CMMotionActivityManager.isActivityAvailable() && CMMotionActivityManager.authorizationStatus() == .authorized {
            if !activityRunning {
                activityRunning = true
                let session = new.sessionID
                motion.startActivityUpdates(to: .main) { [weak self] sample in
                    guard let self, self.profile.enabled, self.profile.activityEnabled, self.activityRunning, self.profile.sessionID == session, let sample else { return }
                    let confidence: Int
                    switch sample.confidence { case .low: confidence = 33; case .medium: confidence = 66; case .high: confidence = 100; @unknown default: confidence = 0 }
                    self.activity?(ActivitySample.map(automotive: sample.automotive, cycling: sample.cycling, running: sample.running, walking: sample.walking, stationary: sample.stationary, confidence: confidence), session)
                }
            }
        } else { stopMotion() }
    }
    private func stopMotion() { if activityRunning { activityRunning = false; motion.stopActivityUpdates() } }
    static func accuracy(_ desired: String) -> CLLocationAccuracy {
        switch desired { case "balanced": return kCLLocationAccuracyHundredMeters; case "low": return kCLLocationAccuracyKilometer; case "passive": return kCLLocationAccuracyThreeKilometers; default: return kCLLocationAccuracyBest }
    }
    func locationManager(_ source: CLLocationManager, didUpdateLocations fixes: [CLLocation]) {
        guard source === manager else { return }
        let valid = fixes.filter { $0.horizontalAccuracy >= 0 && CLLocationCoordinate2DIsValid($0.coordinate) }.map(TrackedLocation.init)
        if let newest = valid.max(by: { $0.time < $1.time }), cachedLocation == nil || newest.time >= cachedLocation!.time { cachedLocation = newest }
        guard profile.enabled else { return }
        locations?(valid, profile.sessionID)
    }
    func locationManager(_ source: CLLocationManager, didFailWithError failure: Error) {
        guard source === manager, profile.enabled, (failure as? CLError)?.code != .locationUnknown else { return }
        let session = profile.sessionID
        LocationServices.shared.refresh { [weak self] in
            guard let self, self.profile.enabled, self.profile.sessionID == session else { return }
            self.authorizationChanged?()
            if LocationServices.shared.enabled { self.error?(TrackingError((failure as? CLError)?.code == .denied ? "PERMISSION_DENIED" : "UNAVAILABLE", "Core Location route updates failed"), session) }
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { authorizationChanged?() }
}

extension TrackedLocation {
    init(_ fix: CLLocation) {
        self.init(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude, accuracy: fix.horizontalAccuracy, altitude: fix.verticalAccuracy >= 0 ? fix.altitude : nil, altitudeAccuracy: fix.verticalAccuracy >= 0 ? fix.verticalAccuracy : nil, speed: fix.speed >= 0 ? fix.speed : nil, speedAccuracy: fix.speedAccuracy >= 0 ? fix.speedAccuracy : nil, heading: fix.course >= 0 ? fix.course : nil, headingAccuracy: fix.courseAccuracy >= 0 ? fix.courseAccuracy : nil, time: fix.timestamp.timeIntervalSince1970 * 1000, isMock: fix.sourceInformation?.isSimulatedBySoftware ?? false)
    }
    var location: CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude), altitude: altitude ?? 0, horizontalAccuracy: accuracy, verticalAccuracy: altitudeAccuracy ?? -1, course: heading ?? -1, courseAccuracy: headingAccuracy ?? -1, speed: speed ?? -1, speedAccuracy: speedAccuracy ?? -1, timestamp: Date(timeIntervalSince1970: time / 1000))
    }
}
