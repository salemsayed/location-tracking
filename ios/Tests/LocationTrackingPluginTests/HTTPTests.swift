import XCTest
@testable import LocationTrackingPlugin

@MainActor
final class HTTPTests: XCTestCase {
    let base = URL(string: "http://127.0.0.1:8787")!
    var store: TrackingStore!
    var config: TrackingConfig!
    var secrets: SecretStore!
    var syncer: Syncer!
    var events: [(String, TrackingJSON)] = []

    func control(_ path: String, _ value: TrackingJSON = [:]) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try jsonData(value)
        return try await URLSession.shared.data(for: request).0
    }
    func prepare(_ http: TrackingJSON = [:], records: Int = 1) async throws {
        _ = try await control("__reset")
        store = try TrackingStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("test.sqlite"))
        secrets = SecretStore(service: "LT.test." + UUID().uuidString)
        config = try TrackingConfig(store: store, secrets: secrets)
        try config.apply(["http": TrackingConfig.merge(["url": base.appendingPathComponent("locations").absoluteString, "autoSync": false], http)], reset: true)
        for n in 0..<records { try store.insert(["uuid": "stable-\(n)", "event": "location", "recorded_at": iso(), "coords": ["latitude": 24.7136, "longitude": 46.6753, "accuracy": 5.2]]) }
        events = []
        syncer = Syncer(queue: .main, store: store, config: config) { [weak self] name, payload in self?.events.append((name, payload)) }
    }
    func upload() async throws -> [TrackingJSON] {
        try await withCheckedThrowingContinuation { continuation in syncer.run { continuation.resume(with: $0) } }
    }
    func testLarge2xxBodyDeletesWithoutParsingAndCapsEvent() async throws {
        try await prepare()
        _ = try await control("__faults", ["path": "/locations", "status": 202, "body": String(repeating: "x", count: 100000)])
        let uploaded = try await upload()
        XCTAssertEqual(uploaded.count, 1)
        XCTAssertEqual(try store.count, 0)
        XCTAssertEqual(events.last?.1.text("responseText").utf8.count, 16384)
        syncer.transport.close()
    }
    func testRedirectRefusedAndRecordsRetained() async throws {
        try await prepare()
        _ = try await control("__faults", ["path": "/locations", "status": 307, "headers": ["Location": base.appendingPathComponent("locations").absoluteString]])
        do { _ = try await upload(); XCTFail("Redirect should fail") } catch {}
        XCTAssertEqual(try store.count, 1)
        XCTAssertEqual(events.last?.1.number("status"), 307)
        syncer.transport.close()
    }
    func test401RefreshesAndRetriesSameUUID() async throws {
        try await prepare(["authorization": ["accessToken": "old", "refreshToken": "refresh", "refreshUrl": base.appendingPathComponent("auth/refresh").absoluteString, "refreshPayload": ["refreshToken": "{refreshToken}"]]])
        _ = try await control("__faults", ["path": "/locations", "status": 401])
        let uploaded = try await upload()
        XCTAssertEqual(uploaded.first?.text("uuid"), "stable-0")
        XCTAssertEqual(try store.count, 0)
        XCTAssertTrue(events.contains { $0.0 == "authorization" && $0.1.flag("success") })
        XCTAssertEqual(events.filter { $0.0 == "http" }.map { $0.1.number("status") }, [401, 200])
        syncer.transport.close()
    }
    func testTokenChangeDuringUploadNeverRefreshesOldPair() async throws {
        try await prepare(["authorization": ["accessToken": "old", "refreshToken": "refresh", "refreshUrl": base.appendingPathComponent("auth/refresh").absoluteString]])
        _ = try await control("__faults", ["path": "/locations", "status": 401, "delayMs": 300])
        let work = Task { try await upload() }
        try await Task.sleep(nanoseconds: 100_000_000)
        try config.apply(["http": ["authorization": ["accessToken": "changed"]]], reset: false)
        do { _ = try await work.value; XCTFail("Changed authorization should retain queue") } catch {}
        XCTAssertEqual(try store.count, 1)
        XCTAssertFalse(events.contains { $0.0 == "authorization" && $0.1.flag("success") })
        syncer.transport.close()
    }
    func test413HalvesBatchWithoutChangingUUIDs() async throws {
        try await prepare(["batchSync": true, "maxBatchSize": 4], records: 4)
        _ = try await control("__faults", ["path": "/locations", "status": 413, "count": -1, "minRecords": 3])
        let uploaded = try await upload()
        XCTAssertEqual(uploaded.map { $0.text("uuid") }, ["stable-0", "stable-1", "stable-2", "stable-3"])
        XCTAssertEqual(try store.count, 0)
        XCTAssertEqual(events.filter { $0.0 == "http" }.map { $0.1.number("status") }, [413, 200, 200])
        syncer.transport.close()
    }
    func testRetryAfterStoredAndQueueSurvivesReopen() async throws {
        try await prepare()
        _ = try await control("__faults", ["path": "/locations", "status": 503, "headers": ["Retry-After": "3600"]])
        do { _ = try await upload(); XCTFail("Expected 503") } catch {}
        XCTAssertEqual(try store.count, 1)
        let wait = try XCTUnwrap(store.load("uploadWait"))
        XCTAssertGreaterThan(wait.number("at") - Date().timeIntervalSince1970 * 1000, 3590000)
        syncer.transport.close()
    }
    func testRetryKeepsUUID() async throws {
        try await prepare()
        _ = try await control("__faults", ["path": "/locations", "status": 500])
        _ = try await upload()
        let requests = events.filter { $0.0 == "http" }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].1["uuids"] as? [String], ["stable-0"])
        XCTAssertEqual(requests[1].1["uuids"] as? [String], ["stable-0"])
        syncer.transport.close()
    }
    func testManualSyncIgnoresCellularAutoRestriction() async throws {
        try await prepare(["disableAutoSyncOnCellular": true])
        syncer.cellular = true
        let uploaded = try await upload()
        XCTAssertEqual(uploaded.count, 1)
        XCTAssertEqual(try store.count, 0)
        syncer.transport.close()
    }
    func testExplicitAuthorizationHeaderWinsOverJWT() async throws {
        try await prepare(["headers": ["authorization": "Custom configured"], "authorization": ["accessToken": "ignored", "refreshToken": "ignored", "expires": 1, "refreshUrl": base.appendingPathComponent("auth/refresh").absoluteString]])
        _ = try await upload()
        XCTAssertFalse(events.contains { $0.0 == "authorization" })
        XCTAssertEqual(try store.count, 0)
        syncer.transport.close()
    }
    func testUnavailableSecretsBlockRequestsUntilReplacement() async throws {
        try await prepare(["authorization": ["accessToken": "old"]])
        try secrets.save(nil)
        config = try TrackingConfig(store: store, secrets: secrets)
        syncer = Syncer(queue: .main, store: store, config: config) { [weak self] name, payload in self?.events.append((name, payload)) }
        do { _ = try await upload(); XCTFail("Unreadable authorization must block uploads") } catch {}
        XCTAssertEqual(try store.count, 1)
        XCTAssertFalse(events.contains { $0.0 == "http" })
        XCTAssertTrue(events.contains { $0.0 == "authorization" && !$0.1.flag("success") })
        try config.apply(["http": ["authorization": ["accessToken": "new"]]], reset: false)
        _ = try await upload()
        XCTAssertEqual(try store.count, 0)
        syncer.transport.close()
    }
    func testTimeoutDoesNotDelete() async throws {
        try await prepare(["timeout": 100])
        _ = try await control("__faults", ["path": "/locations", "delayMs": 2000, "count": -1])
        do { _ = try await upload(); XCTFail("Expected timeout") } catch {}
        XCTAssertEqual(try store.count, 1)
        XCTAssertEqual(events.last?.1.number("status"), 0)
        syncer.transport.close()
    }
}
