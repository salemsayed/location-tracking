import XCTest
@testable import LocationTrackingPlugin

final class LoggingTests: XCTestCase {
    func testRedactionAndPersistence() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("logs.sqlite")
        do {
            let store = try TrackingStore(url: url)
            let log = TrackingLog(store: store)
            log.write("info", "Authorization: Bearer test-token https://example.com/token?secret=value refresh_token=hidden")
        }
        let store = try TrackingStore(url: url)
        let log = TrackingLog(store: store)
        let text = log.read([:])
        XCTAssertFalse(text.contains("test-token"))
        XCTAssertFalse(text.contains("https://"))
        XCTAssertFalse(text.contains("hidden"))
        XCTAssertTrue(text.contains("redacted"))
        try log.clear()
        XCTAssertEqual(log.read([:]), "")
    }
    func testGzipEnvelope() throws {
        let compressed = try LogExport.gzip(Data("location log".utf8))
        XCTAssertEqual(Array(compressed.prefix(2)), [0x1f, 0x8b])
    }
}
