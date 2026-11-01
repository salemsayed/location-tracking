import XCTest
@testable import LocationTrackingPlugin

@MainActor
final class HTTPTests: XCTestCase {
    let base = URL(string: "http://127.0.0.1:8787")!
    var storeURL: URL!
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
        storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("test.sqlite")
        store = try TrackingStore(url: storeURL)
        secrets = SecretStore(service: "LT.test." + UUID().uuidString)
        config = try TrackingConfig(store: store, secrets: secrets)
        try config.apply(["http": TrackingConfig.merge(["url": base.appendingPathComponent("locations").absoluteString, "autoSync": false], http)], reset: true)
        for n in 0..<records { try store.insert(["uuid": "stable-\(n)", "event": "location", "recorded_at": iso(), "coords": ["latitude": 24.7136, "longitude": 46.6753, "accuracy": 5.2]]) }
        events = []
        syncer = Syncer(queue: .main, store: store, config: config) { [weak self] name, payload in self?.events.append((name, payload)) }
        syncer.connectivityKnown = true
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
        syncer.transport.close()
        syncer = nil
        config = nil
        store = nil
        store = try TrackingStore(url: storeURL)
        config = try TrackingConfig(store: store, secrets: secrets)
        syncer = Syncer(queue: .main, store: store, config: config) { [weak self] name, payload in self?.events.append((name, payload)) }
        XCTAssertEqual(try store.locations().map { $0.text("uuid") }, ["stable-0"])
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
        syncer.connectivityKnown = true
        do { _ = try await upload(); XCTFail("Unreadable authorization must block uploads") } catch {}
        XCTAssertEqual(try store.count, 1)
        XCTAssertFalse(events.contains { $0.0 == "http" })
        XCTAssertTrue(events.contains { $0.0 == "authorization" && !$0.1.flag("success") })
        try config.apply(["http": ["authorization": ["accessToken": "new"]]], reset: false)
        _ = try await upload()
        XCTAssertEqual(try store.count, 0)
        syncer.transport.close()
    }
    func testPolicyReevaluatesAfterPriorityUploadWhenNetworkChanges() async throws {
        try await prepare(["autoSync": true, "disableAutoSyncOnCellular": true])
        try store.insert(["uuid": "priority", "event": "heartbeat", "recorded_at": iso()])
        _ = try await control("__faults", ["path": "/locations", "delayMs": 300])
        syncer.cellular = true
        syncer.automatic()
        try await Task.sleep(nanoseconds: 100_000_000)
        syncer.cellular = false
        syncer.automatic()
        let deadline = Date().addingTimeInterval(5)
        while try store.count > 0, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(try store.count, 0)
        XCTAssertEqual(events.filter { $0.0 == "http" }.compactMap { $0.1["uuids"] as? [String] }, [["priority"], ["stable-0"]])
        syncer.transport.close()
    }
    func testGzippedLogUploadUsesRealURLSession() async throws {
        try await prepare(records: 0)
        let exporter = LogExport()
        let response: TrackingJSON = try await withCheckedThrowingContinuation { continuation in
            do { try exporter.upload("Simulator diagnostic", options: ["url": base.appendingPathComponent("logs").absoluteString, "params": ["source": "ios"]]) { continuation.resume(with: $0) } }
            catch { continuation.resume(throwing: error) }
        }
        XCTAssertTrue(response.flag("success"))
        XCTAssertEqual(response.number("status"), 200)
        syncer.transport.close()
    }
    func testBackgroundPassHonorsAutomaticSyncDisabled() async throws {
        try await prepare(["autoSync": false])
        let result: Result<[TrackingJSON], Error> = await withCheckedContinuation { continuation in
            syncer.automatic { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(try result.get().count, 0)
        XCTAssertEqual(try store.count, 1)
        XCTAssertTrue(events.isEmpty)
        syncer.transport.close()
    }
    func test401WithoutJWTUsesServerBackoff() async throws {
        try await prepare()
        _ = try await control("__faults", ["path": "/locations", "status": 401])
        do { _ = try await upload(); XCTFail("Expected HTTP 401") } catch {}
        let wait = try XCTUnwrap(store.load("uploadWait"))
        XCTAssertEqual(wait.text("reason"), "server")
        XCTAssertLessThan(wait.number("at") - Date().timeIntervalSince1970 * 1000, 40000)
        syncer.transport.close()
    }
    func testExplicitHeaderDoesNotDependOnUnusedJWT() async throws {
        try await prepare(["headers": ["Authorization": "Configured credential"], "authorization": ["accessToken": "old"]])
        _ = try await control("__faults", ["path": "/locations", "status": 500, "delayMs": 300])
        let work = Task { try await upload() }
        try await Task.sleep(nanoseconds: 100_000_000)
        try config.apply(["http": ["authorization": ["accessToken": "new"]]], reset: false)
        _ = try await work.value
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
    func waitForQueueToDrain(seconds: Double = 5) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while try store.count > 0, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(try store.count, 0)
    }
    func testZeroAndMinusOneRetentionAllowInsertAndUpload() async throws {
        for maximum in [0, -1] {
            try await prepare(records: 2)
            try config.apply(["persistence": ["maxRecordsToPersist": maximum]], reset: false)
            try store.prune(days: 7, maximum: maximum)
            XCTAssertEqual(try store.count, 2)
            let uploaded = try await upload()
            XCTAssertEqual(uploaded.count, 2)
            syncer.transport.close()
        }
    }
    func testCredentialsReplacementWaitsTenSecondsAndRetainsBusyTrigger() async throws {
        try await prepare(["autoSync": true, "authorization": ["accessToken": "userA"]])
        _ = try await control("__faults", ["path": "/locations", "status": 401, "delayMs": 300])
        let work = Task { try await upload() }
        try await Task.sleep(nanoseconds: 100_000_000)
        try config.apply(["http": ["authorization": ["accessToken": "userB"]]], reset: false)
        syncer.automatic()
        do { _ = try await work.value; XCTFail("Expected changed outcome") } catch {}
        let stopped = Date()
        syncer.automatic()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(events.filter { $0.0 == "http" }.count, 1)
        XCTAssertTrue((try store.load("uploadWait"))?.isEmpty ?? true)
        try await waitForQueueToDrain(seconds: 12)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(stopped), 9.8)
        XCTAssertEqual(events.filter { $0.0 == "http" }.map { $0.1.number("status") }, [401, 200])
        syncer.transport.close()
    }
    func testCredentialsRemovalDuringUploadStartsNoReplacementPass() async throws {
        try await prepare(["autoSync": true, "authorization": ["accessToken": "userA"]])
        _ = try await control("__faults", ["path": "/locations", "status": 401, "delayMs": 300])
        let work = Task { try await upload() }
        try await Task.sleep(nanoseconds: 100_000_000)
        try config.apply(["http": ["authorization": NSNull()]], reset: false)
        syncer.automatic()
        do { _ = try await work.value; XCTFail("Expected changed outcome") } catch {}
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(try store.count, 1)
        XCTAssertEqual(events.filter { $0.0 == "http" }.count, 1)
        XCTAssertFalse(events.contains { $0.0 == "authorization" })
        XCTAssertTrue((try store.load("uploadWait"))?.isEmpty ?? true)
        syncer.transport.close()
    }
    func testCredentialsChangedDuringPreemptiveRefreshAreNotOverwritten() async throws {
        try await prepare(["autoSync": true, "authorization": ["accessToken": "old", "expires": 1, "refreshUrl": base.appendingPathComponent("auth/refresh").absoluteString]])
        _ = try await control("__faults", ["path": "/auth/refresh", "delayMs": 300])
        let work = Task { try await upload() }
        try await Task.sleep(nanoseconds: 100_000_000)
        try config.apply(["http": ["authorization": ["accessToken": "replacement", "expires": -1]]], reset: false)
        syncer.automatic()
        do { _ = try await work.value; XCTFail("Expected changed outcome") } catch {}
        XCTAssertEqual(config.value.object("http").object("authorization").text("accessToken"), "replacement")
        XCTAssertFalse(events.contains { $0.0 == "http" || $0.0 == "authorization" })
        try await waitForQueueToDrain(seconds: 12)
        syncer.transport.close()
    }
    func testCredentialsRemovedDuringRefreshNeverUploadOldToken() async throws {
        try await prepare(["autoSync": true, "authorization": ["accessToken": "old", "expires": 1, "refreshUrl": base.appendingPathComponent("auth/refresh").absoluteString]])
        _ = try await control("__faults", ["path": "/auth/refresh", "delayMs": 300])
        let work = Task { try await upload() }
        try await Task.sleep(nanoseconds: 100_000_000)
        try config.apply(["http": ["authorization": NSNull()]], reset: false)
        do { _ = try await work.value; XCTFail("Expected changed outcome") } catch {}
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(try store.count, 1)
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue((try store.load("uploadWait"))?.isEmpty ?? true)
        syncer.transport.close()
    }
    func testOrdinaryRejectionStillUploadsPriorityRecords() async throws {
        for batch in [false, true] {
            try await prepare(["batchSync": batch])
            try store.insert(["uuid": "priority", "event": "heartbeat", "recorded_at": iso()])
            _ = try await control("__faults", ["path": "/locations", "status": 422])
            do { _ = try await upload(); XCTFail("Ordinary rejection must be reported") } catch {}
            XCTAssertEqual(try store.locations().map { $0.text("uuid") }, ["stable-0"])
            XCTAssertEqual(events.filter { $0.0 == "http" }.compactMap { $0.1["uuids"] as? [String] }, batch ? [["stable-0", "priority"], ["priority"]] : [["stable-0"], ["priority"]])
            syncer.transport.close()
        }
    }
    func testRejectedPriorityIsNotRetriedInSamePass() async throws {
        try await prepare(records: 0)
        try store.insert(["uuid": "rejected", "event": "heartbeat", "recorded_at": iso()])
        try store.insert(["uuid": "later", "event": "tracking_stop", "recorded_at": iso()])
        _ = try await control("__faults", ["path": "/locations", "status": 400])
        do { _ = try await upload(); XCTFail("Expected rejection") } catch {}
        XCTAssertEqual(try store.locations().map { $0.text("uuid") }, ["rejected"])
        XCTAssertEqual(events.filter { $0.0 == "http" }.compactMap { $0.1["uuids"] as? [String] }, [["rejected"], ["later"]])
        syncer.transport.close()
    }
    func testStartupWaitsForInitialNetworkResultAndManualStillBypasses() async throws {
        try await prepare(["autoSync": true, "disableAutoSyncOnCellular": true])
        syncer.connectivityKnown = false
        syncer.automatic()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(events.isEmpty)
        syncer.connectivity(connected: true, cellular: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(events.isEmpty)
        _ = try await upload()
        XCTAssertEqual(try store.count, 0)
        syncer.transport.close()
    }
    func testAuthorizationEventIncludesFullLargeParsedResponse() async throws {
        try await prepare(["authorization": ["accessToken": "old", "expires": 1, "refreshUrl": base.appendingPathComponent("auth/refresh").absoluteString]])
        let response: TrackingJSON = ["padding": String(repeating: "x", count: 40000), "accessToken": "fresh"]
        _ = try await control("__faults", ["path": "/auth/refresh", "body": String(decoding: try jsonData(response), as: UTF8.self)])
        _ = try await upload()
        let event = try XCTUnwrap(events.first { $0.0 == "authorization" }?.1)
        XCTAssertTrue(event.flag("success"))
        XCTAssertEqual(event.number("status"), 200)
        XCTAssertEqual(event.object("response").text("padding").count, 40000)
        XCTAssertEqual(event.object("response").text("accessToken"), "fresh")
        syncer.transport.close()
    }
    func testAuthorizationFailureIncludesStatusAndParsedResponse() async throws {
        try await prepare(["authorization": ["accessToken": "old", "expires": 1, "refreshUrl": base.appendingPathComponent("auth/refresh").absoluteString]])
        _ = try await control("__faults", ["path": "/auth/refresh", "status": 403, "body": "{\"reason\":\"expired\"}"])
        _ = try await upload()
        let event = try XCTUnwrap(events.first { $0.0 == "authorization" }?.1)
        XCTAssertFalse(event.flag("success"))
        XCTAssertEqual(event.number("status"), 403)
        XCTAssertEqual(event.object("response").text("reason"), "expired")
        XCTAssertFalse(event.text("error").isEmpty)
        syncer.transport.close()
    }
    func testAuthorizationTimeoutIncludesZeroStatus() async throws {
        try await prepare(["timeout": 100, "authorization": ["accessToken": "old", "expires": 1, "refreshUrl": base.appendingPathComponent("auth/refresh").absoluteString]])
        _ = try await control("__faults", ["path": "/auth/refresh", "delayMs": 2000])
        _ = try await upload()
        let event = try XCTUnwrap(events.first { $0.0 == "authorization" }?.1)
        XCTAssertEqual(event.number("status"), 0)
        XCTAssertNil(event["response"])
        syncer.transport.close()
    }
    func testReconnectClearsServerWaitButPreservesAuthorizationWait() async throws {
        for reason in ["server", "authorization"] {
            try await prepare(["autoSync": true])
            try store.save("uploadWait", ["at": Date().addingTimeInterval(1000).timeIntervalSince1970 * 1000, "reason": reason, "authKey": UploadBackoff.authKey(config.value.object("http"))])
            syncer.connectivity(connected: false, cellular: false)
            syncer.connectivity(connected: true, cellular: false)
            if reason == "server" { try await waitForQueueToDrain() }
            else {
                try await Task.sleep(nanoseconds: 200_000_000)
                XCTAssertEqual(try store.count, 1)
                XCTAssertTrue(events.isEmpty)
            }
            syncer.transport.close()
        }
    }
    func testReconnectDuringUploadRetainsRecoveryTrigger() async throws {
        try await prepare(["autoSync": true])
        _ = try await control("__faults", ["path": "/locations", "status": 422, "delayMs": 300])
        syncer.automatic()
        try await Task.sleep(nanoseconds: 100_000_000)
        syncer.connectivity(connected: false, cellular: false)
        syncer.connectivity(connected: true, cellular: false)
        try await waitForQueueToDrain()
        XCTAssertEqual(events.filter { $0.0 == "http" }.map { $0.1.number("status") }, [422, 200])
        syncer.transport.close()
    }
    func testBackgroundExpirationCancelsAndCompletesExactlyOnce() async throws {
        try await prepare(["autoSync": true])
        _ = try await control("__faults", ["path": "/locations", "delayMs": 2000])
        var completed: [Bool] = []
        let task = BackgroundUpload(syncer: syncer) { completed.append($0) }
        task.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        task.expire()
        task.expire()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(completed, [false])
        XCTAssertEqual(try store.count, 1)
        syncer.transport.close()
    }

}
