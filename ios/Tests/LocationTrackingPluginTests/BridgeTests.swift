import XCTest
import CoreLocation
@testable import LocationTrackingPlugin

@MainActor
final class BridgeTests: XCTestCase {
    func testMethodTableCoversTypeScriptSurface() {
        let names = Set(LocationTrackingPlugin().pluginMethods.compactMap { $0.name })
        let expected = Set(["ready", "setConfig", "reset", "getState", "start", "startGeofences", "stop", "changePace", "getCurrentPosition", "watchPosition", "clearWatch", "getOdometer", "setOdometer", "resetOdometer", "getLocations", "getCount", "insertLocation", "destroyLocations", "destroyLocation", "sync", "addGeofence", "addGeofences", "removeGeofence", "removeGeofences", "getGeofences", "getGeofence", "geofenceExists", "getHeartbeatStatus", "getProviderState", "isPowerSaveMode", "getBatteryOptimizationStatus", "openBatteryOptimizationSettings", "getPowerManagerInfo", "openPowerManagerSettings", "openLocationSettings", "openAppSettings", "getDeviceInfo", "getSensors", "checkPermissions", "requestPermissions", "requestTemporaryFullAccuracy", "log", "getLog", "destroyLog", "uploadLog", "emailLog"])
        XCTAssertEqual(names, expected)
    }
    func testNotReadyAndNativeBypass() throws {
        let core = try TrackingCore(queue: .main, permissions: Permissions(), positions: Positions(), emit: { _, _ in }, record: { _ in }, url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("test.sqlite"))
        var failure: TrackingError?
        core.call("getCount", [:]) { result in if case .failure(let error) = result { failure = error as? TrackingError } }
        XCTAssertEqual(failure?.code, "NOT_READY")
        var nativeCount: Double?
        core.call("getCount", [:], native: true) { result in nativeCount = (try? result.get())?.number("count") }
        XCTAssertEqual(nativeCount, 0)
        XCTAssertFalse(core.ready)
        core.call("ready", [:]) { result in if case .failure(let error) = result { XCTFail(error.localizedDescription) } }
        XCTAssertTrue(core.ready)
        core.call("getCount", [:]) { result in XCTAssertEqual((try? result.get())?.number("count"), 0) }
        core.syncer.transport.close()
    }
    func testAllowlistMatchesAndroidWithPrecisionAddition() {
        XCTAssertEqual(TrackingCore.allowed, Set(["ready", "getState", "checkPermissions", "requestPermissions", "requestTemporaryFullAccuracy", "getDeviceInfo", "getSensors", "log", "getLog", "getProviderState", "openBatteryOptimizationSettings", "openPowerManagerSettings", "openLocationSettings", "openAppSettings"]))
    }
    func testRecordShapeOmitsUnavailableIDAndCoordinatesAreNullable() {
        let wire = RecordFactory.make(event: "current_position", fix: nil, extras: [:], odometer: 0, provider: [:], network: "none")
        XCTAssertTrue(wire["coords"] is NSNull)
        XCTAssertTrue(wire["timestamp"] is NSNull)
        XCTAssertEqual(wire.number("boot_count"), -1)
        XCTAssertEqual(wire.text("backend"), "corelocation")
        XCTAssertNoThrow(try jsonData(wire))
    }
    func testPermissionOrderMatchesAndroid() {
        XCTAssertEqual(Permissions.order, ["location", "notifications", "activityRecognition", "backgroundLocation"])
    }

}
