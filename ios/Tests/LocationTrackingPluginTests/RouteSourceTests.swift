import XCTest
import CoreLocation
@testable import LocationTrackingPlugin

@MainActor
final class RouteSourceTests: XCTestCase {
    func testLastLocationReadsOnlyTheDelegateCacheAndKeepsTheNewestValidFix() {
        let manager = NoSynchronousLocationManager(), relaunch = NoSynchronousLocationManager()
        let source = RouteSource(manager: manager, relaunch: relaunch)
        var callbacks = 0
        source.locations = { _, _ in callbacks += 1 }
        XCTAssertNil(source.lastLocation)
        let first = EngineFixtures.location(time: 1000), latest = EngineFixtures.location(latitude: 24.8, time: 2000)
        source.locationManager(manager, didUpdateLocations: [latest.location, first.location])
        XCTAssertEqual(source.lastLocation, latest)
        source.locationManager(manager, didUpdateLocations: [first.location])
        XCTAssertEqual(source.lastLocation, latest)
        source.locationManager(relaunch, didUpdateLocations: [EngineFixtures.location(time: 3000).location])
        XCTAssertEqual(source.lastLocation, latest)
        let bad = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 91, longitude: 46), altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1, timestamp: Date(timeIntervalSince1970: 4))
        source.locationManager(manager, didUpdateLocations: [bad])
        XCTAssertEqual(source.lastLocation, latest)
        XCTAssertEqual(callbacks, 0)
    }
}

private final class NoSynchronousLocationManager: CLLocationManager {
    override var location: CLLocation? { XCTFail("The route source must not synchronously query Core Location"); return nil }
}
