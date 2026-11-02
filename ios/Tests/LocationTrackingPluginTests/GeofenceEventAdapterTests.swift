import XCTest
import CoreLocation
@testable import LocationTrackingPlugin

final class GeofenceEventAdapterTests: XCTestCase {
    let adapter = GeofenceEventAdapter()
    func actions(_ id: String, _ state: MonitorState, _ diagnostics: [(String, String)] = []) -> [String] {
        adapter.handle(id, state, failures: diagnostics).0.map { $0.action.rawValue + ($0.initial ? ":initial" : "") }
    }

    func testInitialTriggerEntryFalseKeepsAUserAlreadyInsideSilentAndReportsLaterTransitions() {
        adapter.registered("home", initialTriggerEntry: false)
        XCTAssertEqual(actions("home", .satisfied), [])
        XCTAssertEqual(actions("home", .satisfied), [])
        XCTAssertEqual(actions("home", .unsatisfied), ["EXIT"])
        XCTAssertEqual(actions("home", .satisfied), ["ENTER"])
    }
    func testInitialTriggerEntryTrueReportsTheInitialInsideState() {
        adapter.registered("home", initialTriggerEntry: true)
        XCTAssertEqual(actions("home", .satisfied), ["ENTER"])
        XCTAssertEqual(actions("home", .unsatisfied), ["EXIT"])
    }
    func testAnInitialOutsideDeterminationIsMarkedInitialAndARealEntryFollows() {
        adapter.registered("home", initialTriggerEntry: false)
        XCTAssertEqual(actions("home", .unsatisfied), ["EXIT:initial"])
        XCTAssertEqual(actions("home", .satisfied), ["ENTER"])
    }
    func testUnknownUnmonitoredAndDiagnosticEventsDoNotConsumeTheInitialDetermination() {
        adapter.registered("home", initialTriggerEntry: false)
        XCTAssertEqual(actions("home", .unknown), [])
        XCTAssertEqual(actions("home", .unmonitored), [])
        let (transitions, failures) = adapter.handle("home", .satisfied, failures: [("TOO_MANY_GEOFENCES", "limit")])
        XCTAssertTrue(transitions.isEmpty); XCTAssertEqual(failures, [MonitorFailure(id: "home", code: "TOO_MANY_GEOFENCES", message: "geofence 'home': limit")])
        XCTAssertEqual(actions("home", .satisfied), [], "the user already inside stays silent")
        XCTAssertEqual(actions("home", .unsatisfied), ["EXIT"])
    }
    func testAPersistedInsideStateReportsTheExitMissedWhileTheAppWasGone() {
        adapter.seed("home", .satisfied)
        adapter.seed("home", .unsatisfied)
        XCTAssertEqual(actions("home", .unsatisfied), ["EXIT"])
        XCTAssertEqual(actions("home", .unsatisfied), [])
    }
    func testFailuresAreReportedOncePerGeofenceAndCodeUntilAHealthyEvent() {
        adapter.registered("home", initialTriggerEntry: true)
        XCTAssertEqual(adapter.handle("home", .unknown, failures: [("TOO_MANY_GEOFENCES", "limit")]).1.count, 1)
        XCTAssertEqual(adapter.handle("home", .unknown, failures: [("TOO_MANY_GEOFENCES", "limit")]).1.count, 0)
        XCTAssertEqual(adapter.handle("home", .unknown, failures: [("PERMISSION_DENIED", "approximate")]).1.map(\.code), ["PERMISSION_DENIED"])
        XCTAssertEqual(actions("home", .satisfied), ["ENTER"])
        XCTAssertEqual(adapter.handle("home", .unknown, failures: [("TOO_MANY_GEOFENCES", "limit")]).1.count, 1)
    }
    func testRemovedAndUnknownIdentifiersAreIgnored() {
        adapter.registered("home", initialTriggerEntry: true)
        adapter.removed("home")
        XCTAssertEqual(actions("home", .satisfied), [])
        XCTAssertEqual(actions("ghost", .unsatisfied), [])
        adapter.registered("a", initialTriggerEntry: true); adapter.registered("b", initialTriggerEntry: true)
        adapter.retain(["b"])
        XCTAssertEqual(actions("a", .satisfied), []); XCTAssertEqual(actions("b", .satisfied), ["ENTER"])
    }
    func testTheMonitorDoesNotOpenWhileLocationAuthorizationIsUndetermined() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("CLMonitor requires iOS 17") }
        var status = CLAuthorizationStatus.notDetermined
        let monitor = GeofenceMonitor(name: "LocationTrackingTests", queue: .main) { status }
        monitor.add([OsGeofence(id: "home", latitude: 24.7136, longitude: 46.6753, radius: 100, onEntry: true, onExit: true, initialTriggerEntry: true)])
        monitor.remove(["home"]); monitor.retain([]); monitor.holdSession(false)
        XCTAssertFalse(monitor.isOpen)
        status = .denied
        monitor.retain([])
        XCTAssertTrue(monitor.isOpen)
    }
}
