import Foundation

final class Syncer {
    let transport = HTTPTransport()
    private let queue: DispatchQueue
    private let store: TrackingStore
    private let config: TrackingConfig
    private let emit: (String, TrackingJSON) -> Void
    private var callbacks: [(Result<[TrackingJSON], Error>) -> Void] = []
    private var uploaded: [TrackingJSON] = []
    private var reducedBatch: Int?
    private var busy = false
    private var priorityOnly = false
    private var generation = 0
    private var shortLivedToken: String?
    private var failures = 0
    private var retryTimer: DispatchWorkItem?
    var connected = true
    var cellular = false
    var tracking = false
    private let priority = Set(["heartbeat", "tracking_start", "tracking_stop", "providerchange"])
    init(queue: DispatchQueue, store: TrackingStore, config: TrackingConfig, emit: @escaping (String, TrackingJSON) -> Void) {
        self.queue = queue; self.store = store; self.config = config; self.emit = emit
        failures = Int((try? store.load("uploadWait"))?.number("failures") ?? 0)
    }
    func cancel() {
        generation += 1
        transport.cancel()
        if busy { finish(.failure(TrackingError("NETWORK_ERROR", "Upload cancelled"))) }
    }
    func automatic(completion: ((Result<[TrackingJSON], Error>) -> Void)? = nil) {
        if busy {
            if let completion { callbacks.append(completion) }
            return
        }
        guard connected, let records = try? store.locations(), !records.isEmpty else { completion?(.success([])); return }
        let http = config.value.object("http")
        guard !http.text("url").isEmpty else { completion?(.success([])); return }
        let hasPriority = records.contains { priority.contains($0.text("event")) }
        if hasPriority { run(priorityOnly: cellular && http.flag("disableAutoSyncOnCellular"), completion: completion ?? { _ in }); return }
        guard http.flag("autoSync", true), !(cellular && http.flag("disableAutoSyncOnCellular")) else { completion?(.success([])); return }
        if let wait = try? store.load("uploadWait"), wait.number("at") > Date().timeIntervalSince1970 * 1000,
           wait.text("reason") != "authorization" || wait.text("authKey") == UploadBackoff.authKey(http) { schedule(wait.number("at")); completion?(.success([])); return }
        let interval = tracking ? http.number("syncInterval") : 0
        let threshold = http.number("autoSyncThreshold")
        if interval > 0, let oldest = records.first {
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let age = Date().timeIntervalSince(formatter.date(from: oldest.text("recorded_at")) ?? .distantPast)
            if age >= 0 && age < interval && !(threshold > 0 && Double(records.count) >= threshold) { schedule(Date().timeIntervalSince1970 * 1000 + (interval - age) * 1000); completion?(.success([])); return }
        } else if Double(records.count) < max(1, threshold) { completion?(.success([])); return }
        run(completion: completion ?? { _ in })
    }
    func run(priorityOnly: Bool = false, completion: @escaping (Result<[TrackingJSON], Error>) -> Void) {
        guard !config.value.object("http").text("url").isEmpty else { completion(.failure(TrackingError("NO_URL", "No http.url configured"))); return }
        callbacks.append(completion)
        if busy { if !priorityOnly { self.priorityOnly = false }; return }
        self.priorityOnly = priorityOnly
        busy = true; uploaded = []; reducedBatch = nil
        next()
    }
    private func next() {
        do {
            let http = config.value.object("http")
            let limit = http.flag("batchSync") ? max(1, Int(http.number("maxBatchSize", 100))) : 1
            let size = reducedBatch.map { min(limit, $0) } ?? limit
            let chunk = priorityOnly ? Array(try store.locations().filter { priority.contains($0.text("event")) }.prefix(size)) : try store.locations(limit: size)
            if chunk.isEmpty { failures = 0; try store.save("uploadWait", [:]); finish(.success(uploaded)); return }
            upload(chunk, http: http, attempt: 0, refreshed: false)
        } catch { finish(.failure(error)) }
    }
    private func upload(_ records: [TrackingJSON], http: TrackingJSON, attempt: Int, refreshed: Bool) {
        let captured = generation
        if config.secretsUnavailable {
            emit("authorization", ["success": false, "status": 0, "error": "Stored authorization is unavailable; set http.authorization again"])
            fail(TrackingError("HTTP_ERROR", "Stored authorization is unavailable; set http.authorization again"), http: http, status: 401, retryAfter: nil)
            return
        }
        guard UploadBackoff.authKey(http) == UploadBackoff.authKey(config.value.object("http")) else { finish(.failure(TrackingError("HTTP_ERROR", "Authorization changed; records retained"))); automatic(); return }
        let explicitAuthorization = http.object("headers").keys.contains { $0.lowercased() == "authorization" }
        let auth = explicitAuthorization ? [:] : http.object("authorization")
        let expires = auth.number("expires", -1)
        if !auth.isEmpty && !auth.text("refreshUrl").isEmpty && !refreshed && (auth.text("accessToken").isEmpty || (expires > 0 && Date().timeIntervalSince1970 * 1000 >= expires - 60000 && auth.text("accessToken") != shortLivedToken)) {
            refresh(http) { result in
                guard self.generation == captured else { return }
                switch result {
                case .success(let fresh): self.upload(records, http: fresh, attempt: attempt, refreshed: true)
                case .failure(let error):
                    if !auth.text("accessToken").isEmpty { self.upload(records, http: http, attempt: attempt, refreshed: true) }
                    else { self.fail(error, http: http, status: 401, retryAfter: nil) }
                }
            }
            return
        }
        do {
            guard let url = URL(string: http.text("url")), ["http", "https"].contains(url.scheme ?? "") else { throw TrackingError("INVALID_ARGUMENT", "Invalid upload URL") }
            var headers = http["headers"] as? [String: String] ?? [:]
            if !auth.text("accessToken").isEmpty { headers = headers.filter { $0.key.lowercased() != "authorization" }; headers["Authorization"] = "Bearer " + auth.text("accessToken") }
            let body = try BodyBuilder.build(records, http: http)
            transport.send(url: url, method: http.text("method", "POST"), headers: headers, body: body, timeout: http.number("timeout", 60000)) { result in
                self.queue.async {
                    guard self.generation == captured, self.busy else { return }
                    let response = try? result.get()
                    let status = response?.status ?? 0
                    self.emit("http", ["success": response?.success ?? false, "status": status, "responseText": response.map { String(decoding: $0.body, as: UTF8.self) } ?? "Network request failed", "uuids": records.map { $0.text("uuid") }])
                    if response?.success == true {
                        do {
                            try self.store.transaction { for record in records { try self.store.delete(record.text("uuid")) } }
                            self.uploaded += records
                            self.next()
                        } catch { self.finish(.failure(error)) }
                        return
                    }
                    if UploadBackoff.authKey(http) != UploadBackoff.authKey(self.config.value.object("http")) {
                        self.finish(.failure(TrackingError("HTTP_ERROR", "Authorization changed; records retained"))); self.automatic(); return
                    }
                    if status == 401 && !refreshed && !auth.isEmpty {
                        self.refresh(http) { renewal in
                            guard self.generation == captured else { return }
                            switch renewal {
                            case .success(let fresh): self.upload(records, http: fresh, attempt: attempt, refreshed: true)
                            case .failure(let error): self.fail(error, http: http, status: 401, retryAfter: nil)
                            }
                        }
                        return
                    }
                    if status == 413 && records.count > 1 { self.reducedBatch = max(1, records.count / 2); self.next(); return }
                    let retryAfter = (status == 429 || status == 503) ? UploadBackoff.retryAfter(response?.retryAfter, maximum: http.number("maxRetryAfter", 3600)) : nil
                    if (status == 0 || status == 429 || status >= 500), attempt < 3 {
                        let delay = UploadBackoff.retryDelay(attempt, random: Double.random(in: 0..<1))
                        if (retryAfter ?? 0) <= delay {
                            self.queue.asyncAfter(deadline: .now() + delay / 1000) {
                                guard self.generation == captured, self.busy else { return }
                                self.upload(records, http: http, attempt: attempt + 1, refreshed: refreshed)
                            }
                            return
                        }
                    }
                    self.fail(TrackingError(status == 0 ? "NETWORK_ERROR" : "HTTP_ERROR", status == 0 ? "Network request failed" : "Upload failed: HTTP \(status)"), http: http, status: status, retryAfter: retryAfter)
                }
            }
        } catch { finish(.failure(error)) }
    }
    private func refresh(_ http: TrackingJSON, completion: @escaping (Result<TrackingJSON, Error>) -> Void) {
        let auth = http.object("authorization")
        guard let url = URL(string: auth.text("refreshUrl")), ["http", "https"].contains(url.scheme ?? "") else { completion(.failure(TrackingError("HTTP_ERROR", "Token refresh is not configured"))); return }
        var payload = auth.object("refreshPayload")
        for (key, value) in payload { if let text = value as? String { payload[key] = text.replacingOccurrences(of: "{refreshToken}", with: auth.text("refreshToken")) } }
        do {
            var headers = auth["refreshHeaders"] as? [String: String] ?? [:]
            let body: Data
            if auth.text("refreshPayloadEncoding", "json") == "form" {
                var components = URLComponents()
                components.queryItems = payload.map { URLQueryItem(name: $0.key, value: String(describing: $0.value)) }
                body = Data((components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
                headers["Content-Type"] = "application/x-www-form-urlencoded"
            } else { body = try jsonData(payload) }
            let captured = generation
            transport.send(url: url, method: "POST", headers: headers, body: body, timeout: http.number("timeout", 60000)) { result in
                self.queue.async {
                    guard captured == self.generation else { return }
                    do {
                        guard UploadBackoff.authKey(http) == UploadBackoff.authKey(self.config.value.object("http")) else { throw TrackingError("HTTP_ERROR", "Authorization changed during refresh") }
                        let response = try result.get()
                        let json = try jsonObject(response.body)
                        let access = json.text("accessToken", json.text("access_token"))
                        guard response.success, !access.isEmpty else { throw TrackingError("HTTP_ERROR", "Token refresh failed") }
                        var next = auth
                        next["accessToken"] = access
                        next["refreshToken"] = json.text("refreshToken", json.text("refresh_token", auth.text("refreshToken")))
                        var expires = json.number("expires", json.number("expires_at", -1))
                        if expires > 0 && expires < 1e12 { expires *= 1000 }
                        if expires <= 0 && json.number("expires_in") > 0 { expires = Date().timeIntervalSince1970 * 1000 + json.number("expires_in") * 1000 }
                        next["expires"] = expires
                        try self.config.apply(["http": ["authorization": next]], reset: false)
                        if expires > 0 && expires - Date().timeIntervalSince1970 * 1000 <= 60000 { self.shortLivedToken = access }
                        self.emit("authorization", ["success": true, "status": response.status])
                        completion(.success(self.config.value.object("http")))
                    } catch {
                        self.emit("authorization", ["success": false, "error": "Token refresh failed"])
                        completion(.failure(error))
                    }
                }
            }
        } catch { completion(.failure(error)) }
    }
    private func fail(_ error: Error, http: TrackingJSON, status: Int, retryAfter: Double?) {
        failures += 1
        let delay = status == 401 ? 900000 : UploadBackoff.serverWait(failures, random: Double.random(in: 0..<1), retryAfter: retryAfter, minimum: tracking ? http.number("syncInterval") * 1000 : 0)
        let at = Date().timeIntervalSince1970 * 1000 + delay
        do { try store.save("uploadWait", ["at": at, "reason": status == 401 ? "authorization" : "server", "failures": failures, "authKey": UploadBackoff.authKey(http)]) }
        catch { finish(.failure(error)); return }
        schedule(at)
        finish(.failure(error))
    }
    private func schedule(_ at: Double) {
        retryTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.automatic() }
        retryTimer = item
        queue.asyncAfter(deadline: .now() + max(0.1, at / 1000 - Date().timeIntervalSince1970), execute: item)
    }
    private func finish(_ result: Result<[TrackingJSON], Error>) {
        busy = false
        let waiting = callbacks; callbacks = []
        waiting.forEach { $0(result) }
        if case .success = result { queue.async { [weak self] in self?.automatic() } }
    }
}
