import XCTest
@testable import LocationTrackingPlugin

final class ConfigTests: XCTestCase {
    func config() throws -> (TrackingStore, TrackingConfig, SecretStore) {
        let store = try TrackingStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("config.sqlite"))
        let secrets = SecretStore(service: "LT.config.test." + UUID().uuidString)
        return (store, try TrackingConfig(store: store, secrets: secrets), secrets)
    }
    func testSecretsOnlyInKeychainAndMaskedRoundTrip() throws {
        let (store, config, secrets) = try config()
        defer { try? secrets.save(nil) }
        try config.apply(["http": ["authorization": ["accessToken": "test-access-value", "refreshToken": "test-refresh-value", "refreshHeaders": ["X-Key": "secret"], "refreshPayload": ["refresh": "{refreshToken}"]]]], reset: true)
        XCTAssertEqual(try secrets.load()?.text("accessToken"), "test-access-value")
        XCTAssertTrue(try store.load("config")?.object("http")["authorization"] is NSNull)
        XCTAssertEqual(config.masked.object("http").object("authorization").text("accessToken"), "***alue")
        try config.apply(config.masked, reset: false)
        XCTAssertEqual(config.value.object("http").object("authorization").text("accessToken"), "test-access-value")
    }
    func testFreeFormMapsReplaceRatherThanMerge() throws {
        let (_, config, _) = try config()
        try config.apply(["http": ["headers": ["old": "value"]]], reset: true)
        try config.apply(["http": ["headers": ["new": "value"]]], reset: false)
        XCTAssertNil(config.value.object("http").object("headers")["old"])
    }
    func testCheckInDelayClampsWithWarning() throws {
        let (_, config, _) = try config()
        let warnings = try config.apply(["notification": ["resume": ["delay": 100]], "heartbeat": ["maxInterval": 700]], reset: true)
        XCTAssertEqual(config.value.object("notification").object("resume").number("delay"), 760)
        XCTAssertEqual(warnings.count, 1)
    }
    func testInvalidHTTPConfigRejectedBeforePersistence() throws {
        let (store, config, _) = try config()
        XCTAssertThrowsError(try config.apply(["http": ["url": "file:///secret"]], reset: true))
        XCTAssertNil(try store.load("config"))
    }
}
