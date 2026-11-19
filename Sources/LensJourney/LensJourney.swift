import Foundation

public actor LensJourney {
    /// The SDK version. Keep it equal to `VERSION` and the newest `##` heading in `CHANGELOG.md` (the release version check compares all three).
    public static let version = "0.4.0"
    public typealias Sleeper = @Sendable (UInt64) async throws -> Void
    public typealias Clock = @Sendable () -> Date
    private let config: JourneyConfig
    private let transport: Transport
    private let sleeper: Sleeper?
    private let clock: Clock
    private var category: String?
    private var frame: FrameRef?
    private var vision: VisionType = .distance
    private var prescription: Prescription?
    private var picks: [(node: String, option: String)] = []
    private var history: [Snapshot] = []
    private var finishKey: String?
    private var state: JourneyState?
    private var operationInFlight = false

    /// - Parameters:
    ///   - sleep: Waits before the single 429/503 retry. `nil` (the default) means `Task.sleep(nanoseconds:)`: it honours task
    ///     cancellation, so a cancelled call throws `CancellationError` and never sends the retry. Tests inject a recorder or a no-op.
    ///   - clock: The current time, used to turn an HTTP-date `Retry-After` into a delay.
    public init(config: JourneyConfig, transport: Transport, sleep: Sleeper? = nil, clock: @escaping Clock = Date.init) {
        self.config = config; self.transport = transport; self.sleeper = sleep; self.clock = clock
    }

    public func start(category: String, frame: FrameRef?, vision: VisionType) async throws -> JourneyState {
        try beginOperation()
        do { let value = try await startLocked(category: category, frame: frame, vision: vision); endOperation(); return value } catch { endOperation(); throw error }
    }

    private func startLocked(category: String, frame: FrameRef?, vision: VisionType) async throws -> JourneyState {
        guard category.count <= 100 else { throw LensJourneyError(kind: .invalidRequest, code: "INVALID_REQUEST", message: "category exceeds 100 characters") }
        let nextPrescription = self.category == nil || self.category == category ? prescription : nil
        let next = try await evaluate(category: category, frame: frame, vision: vision, prescription: nextPrescription, picks: [])
        self.category = category; self.frame = frame; self.vision = vision; self.prescription = nextPrescription
        self.picks = []; self.history = []; self.state = next; self.finishKey = nil
        return next
    }

    public func select(optionId: String) async throws -> JourneyState {
        try beginOperation()
        do { let value = try await selectLocked(optionId: optionId); endOperation(); return value } catch { endOperation(); throw error }
    }

    private func selectLocked(optionId: String) async throws -> JourneyState {
        guard let step = state?.step else { throw LensJourneyError(kind: .invalidState, code: "INVALID_STATE", message: "No choice is available") }
        let node = step.id
        try validateId(node); try validateId(optionId)
        guard step.options.contains(where: { $0.id == optionId && $0.enabled }) else { throw LensJourneyError(kind: .invalidSelection, code: "INVALID_SELECTION", message: "The selection is not enabled for the current step") }
        guard Set(picks.map { $0.node }).count < 64 || picks.contains(where: { $0.node == node }) else { throw LensJourneyError(kind: .invalidRequest, code: "INVALID_REQUEST", message: "Selections exceed 64 nodes") }
        var nextPicks = picks
        if step.selectionMode == .multiple {
            if nextPicks.contains(where: { $0.node == node && $0.option == optionId }) { return state! }
            guard nextPicks.filter({ $0.node == node }).count < 16 else { throw LensJourneyError(kind: .invalidRequest, code: "INVALID_REQUEST", message: "Selections exceed 16 ids for a node") }
        } else { nextPicks.removeAll { $0.node == node } }
        nextPicks.append((node, optionId))
        let next = try await evaluate(category: try currentCategory(), frame: frame, vision: vision, prescription: prescription, picks: nextPicks)
        if let current = state { history.append(Snapshot(state: current, picks: picks, prescription: prescription)) }
        picks = nextPicks; state = next; finishKey = nil
        return next
    }

    /// Local undo of the last select (native SDK contract section 4: "local, drops the last pick").
    /// Throws `.invalidRequest` when there is nothing to undo: before start, right after start, and once every pick is undone.
    /// After a `setPrescription`, the restored step's prescription check follows the current prescription, but its options, `enabled`
    /// flags and gate are as they were when that step was evaluated. This is display only: the server re-evaluates on the next `select`.
    public func back() throws -> JourneyState {
        guard !operationInFlight else { throw LensJourneyError(kind: .busy, code: "BUSY", message: "Another journey operation is in progress") }
        guard let previous = history.popLast() else { throw LensJourneyError(kind: .invalidRequest, code: "INVALID_REQUEST", message: "There is no previous selection") }
        picks = previous.picks
        // The prescription check describes the current prescription, not the picks, so it follows a later setPrescription.
        let restored = state.map { current in previous.prescription != prescription ? previous.state.replacingPrescription(current.prescription) : previous.state } ?? previous.state
        state = restored; finishKey = nil
        return restored
    }

    public func setPrescription(_ rx: Prescription) async throws -> JourneyState {
        try beginOperation()
        do { let value = try await setPrescriptionLocked(rx); endOperation(); return value } catch { endOperation(); throw error }
    }

    private func setPrescriptionLocked(_ rx: Prescription) async throws -> JourneyState {
        guard category != nil else { prescription = rx; finishKey = nil; return emptyState() }
        let next = try await evaluate(category: try currentCategory(), frame: frame, vision: vision, prescription: rx, picks: picks)
        // No history entry: back() undoes picks only, so the history stays one entry per pick.
        prescription = rx; state = next; finishKey = nil
        return next
    }

    public func scanPrescription(photo: Data, preparer: ImagePreparer) async throws -> PrescriptionDraft {
        try beginOperation()
        do { let value = try await scanLocked(photo: photo, preparer: preparer); endOperation(); return value } catch { endOperation(); throw error }
    }

    private func scanLocked(photo: Data, preparer: ImagePreparer) async throws -> PrescriptionDraft {
        guard !photo.isEmpty, photo.count <= 10 * 1024 * 1024 else { throw LensJourneyError(kind: .payloadTooLarge, code: "PAYLOAD_TOO_LARGE", message: "Image must not exceed 10 MB") }
        let prepared = try preparer.prepare(photo)
        guard prepared.mimeType.hasPrefix("image/"), isRecognizedImage(prepared.data), prepared.data.count <= 10 * 1024 * 1024 else { throw LensJourneyError(kind: .invalidImage, code: "INVALID_IMAGE", message: "Prepared data must be an image under 10 MB") }
        let boundary = "LensJourney-\(UUID().uuidString)"
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"prescription.jpg\"\r\nContent-Type: \(prepared.mimeType)\r\n\r\n".utf8)
        body.append(prepared.data); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let response = try await sendWithRetry(TransportRequest(method: "POST", path: "/api/v1/lens-journey/rx-ocr", headers: clientHeaders, body: body, contentType: "multipart/form-data; boundary=\(boundary)"))
        return PrescriptionDraft(prescription: try decodeSuccess(OCRResponse.self, from: response).prescription)
    }

    public func finish() async throws -> LensConfiguration {
        try beginOperation()
        do { let value = try await finishLocked(); endOperation(); return value } catch { endOperation(); throw error }
    }

    private func finishLocked() async throws -> LensConfiguration {
        guard let category, !picks.isEmpty, state?.terminal == .summary else { throw LensJourneyError(kind: .journeyIncomplete, code: "JOURNEY_INCOMPLETE", message: "Journey must reach summary before finish") }
        // One key per journey + selection set: repeated finish() calls (after a surfaced 503 or a network error) reuse it so the
        // server can dedupe; start, select, back and setPrescription clear it. The in-call 429/503 retry resends the same body.
        let key = finishKey ?? UUID().uuidString
        finishKey = key
        var body: [String: Any] = ["category": category, "session_id": config.sessionId, "idempotency_key": key,
            "selections": picks.map { ["node_id": $0.node, "option_id": $0.option] }]
        if let prescription { body["prescription"] = try jsonObject(prescription) }
        if let frame {
            // POST /configurations reads the frame from the top-level `product_id` / `product_sku` fields (it looks the product up
            // in its own catalogue); a `frame.sku` is ignored there. Send the SKU where the server reads it, as the Android SDK does.
            if let sku = frame.sku { guard sku.count <= 200 else { throw LensJourneyError(kind: .invalidRequest, code: "INVALID_REQUEST", message: "Frame sku exceeds 200 characters") }; body["product_sku"] = sku }
            if let productId = frame.productId { guard productId.count <= 200 else { throw LensJourneyError(kind: .invalidRequest, code: "INVALID_REQUEST", message: "Frame product id exceeds 200 characters") }; body["product_id"] = productId }
        }
        body["vision_type"] = vision.rawValue
        if let brand = config.wireBrand { body["brand"] = brand }
        let data = try JSONSerialization.data(withJSONObject: body)
        let response = try await sendWithRetry(TransportRequest(method: "POST", path: "/api/v1/lens-journey/configurations", headers: clientHeaders, body: data, contentType: "application/json"))
        return try decodeSuccess(LensConfiguration.self, from: response)
    }

    private func evaluate(category: String, frame: FrameRef?, vision: VisionType, prescription: Prescription?, picks: [(node: String, option: String)]) async throws -> JourneyState {
        let selections = picks.reduce(into: [String: [String]]()) { $0[$1.node, default: []].append($1.option) }
        var body: [String: Any] = ["category": category, "selections": selections, "vision_type": vision.rawValue]
        if let frame { body["frame"] = try jsonObject(frame) }
        if let prescription { body["prescription"] = try jsonObject(prescription) }
        if let currency = config.currency { body["currency"] = currency }
        if let store = config.store { body["store"] = store }
        if let brand = config.wireBrand { body["brand"] = brand }
        let data = try JSONSerialization.data(withJSONObject: body)
        guard data.count <= 16 * 1024 else { throw LensJourneyError(kind: .requestTooLarge, code: "REQUEST_TOO_LARGE", message: "Evaluate request exceeds 16 KB") }
        let response = try await sendWithRetry(TransportRequest(method: "POST", path: "/api/v1/lens-journey/evaluate", headers: clientHeaders, body: data, contentType: "application/json"))
        return try decodeSuccess(JourneyState.self, from: response)
    }

    private var clientHeaders: [String: String] { ["X-Client-Id": config.clientId] }

    private func sendWithRetry(_ request: TransportRequest) async throws -> TransportResponse {
        var retry = 0
        while true {
            let response: TransportResponse
            do { response = try await transport.send(request) }
            catch is CancellationError { throw CancellationError() }
            catch let error as URLError where error.code == .cancelled { throw error }
            catch let error as LensJourneyError { throw error }
            catch { throw LensJourneyError(kind: .network, code: "NETWORK_ERROR", message: error.localizedDescription) }
            if (200...299).contains(response.status) { return response }
            if retry == 0 && (response.status == 429 || response.status == 503) {
                retry += 1
                let delay: UInt64 = response.status == 429 ? retryAfterNanoseconds(response.headers) : 100_000_000
                // Deliberately no default-argument sleeper closure (`sleep: Sleeper = { try await Task.sleep(nanoseconds: $0) }`): calling one
                // crashed debug XCTest runs on Swift 6.3.3 ("freed pointer was not the last allocation"). Root cause unidentified.
                // Do not simplify this back to a default closure.
                if let sleeper { try await sleeper(delay) } else { try await Task.sleep(nanoseconds: delay) }
                continue
            }
            throw decodeError(response)
        }
    }

    /// A 2xx whose body does not decode is a typed error, not a raw `DecodingError`; nothing has been committed when it is thrown.
    private func decodeSuccess<T: Decodable>(_ type: T.Type, from response: TransportResponse) throws -> T {
        do { return try JSONDecoder().decode(type, from: response.body) }
        catch { throw LensJourneyError(kind: .malformedResponse, code: "MALFORMED_RESPONSE", message: "The server answered \(response.status) with a body the SDK could not read") }
    }

    private func decodeError(_ response: TransportResponse) -> LensJourneyError {
        let envelope = (try? JSONDecoder().decode(ErrorEnvelope.self, from: response.body)) ?? ErrorEnvelope()
        let code = envelope.code ?? envelope.error
        let kind: LensJourneyError.Kind
        switch response.status { case 400: kind = code == "INVALID_CLIENT_ID" ? .invalidClientId : .invalidRequest; case 401: kind = .unauthorized; case 403: kind = .insufficientScope; case 404: kind = .workflowNotPublished; case 413: kind = .payloadTooLarge; case 415: kind = .unsupportedMediaType; case 422: kind = .unprocessable; case 429: kind = .rateLimited; case 503: kind = .unavailable; default: kind = .unavailable }
        return LensJourneyError(kind: kind, code: code, message: envelope.message ?? envelope.error ?? "Request failed", details: envelope.details, requestId: envelope.requestId, documentationURL: envelope.documentationURL)
    }
    private func retryAfterNanoseconds(_ headers: [String: String]) -> UInt64 {
        guard let raw = headers.first(where: { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame })?.value.trimmingCharacters(in: .whitespacesAndNewlines) else { return 1_000_000_000 }
        if let seconds = Int64(raw) { return seconds >= 0 ? UInt64(min(seconds, 30)) * 1_000_000_000 : 1_000_000_000 }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: raw) else { return 1_000_000_000 }
        let delta = date.timeIntervalSince(clock())
        guard delta.isFinite, delta >= 0 else { return 1_000_000_000 }
        return UInt64(min(delta, 30) * 1_000_000_000)
    }
    private func beginOperation() throws { guard !operationInFlight else { throw LensJourneyError(kind: .busy, code: "BUSY", message: "Another journey operation is in progress") }; operationInFlight = true }
    private func endOperation() { operationInFlight = false }
    private func currentCategory() throws -> String { guard let category else { throw LensJourneyError(kind: .invalidState, code: "INVALID_STATE", message: "Start the journey first") }; return category }
    private func validateId(_ id: String) throws { guard id.count <= 128 else { throw LensJourneyError(kind: .invalidRequest, code: "INVALID_REQUEST", message: "Selection ids must not exceed 128 characters") } }
    private func isRecognizedImage(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0xff, 0xd8, 0xff]) || bytes.starts(with: [0x89, 0x50, 0x4e, 0x47]) || bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return true }
        if bytes.count >= 12, Array(bytes[0..<4]) == [0x52, 0x49, 0x46, 0x46], Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return true }
        if bytes.count >= 12, String(bytes: bytes[4..<12], encoding: .ascii)?.contains("ftyp") == true { return true }
        return false
    }
    private func emptyState() -> JourneyState { JourneyState(workflowVersion: nil, category: category ?? "", terminal: .unknown, step: nil, selections: [:], autoSelected: [], violations: [], prescription: nil, settingsWarnings: [], gate: nil) }
}

/// What back() restores: the state shown before a pick, the picks at that time, and the prescription it was evaluated with.
private struct Snapshot { let state: JourneyState; let picks: [(node: String, option: String)]; let prescription: Prescription? }

private extension JourneyState {
    func replacingPrescription(_ check: PrescriptionCheck?) -> JourneyState {
        JourneyState(workflowVersion: workflowVersion, category: category, terminal: terminal, step: step, selections: selections, autoSelected: autoSelected, violations: violations, prescription: check, settingsWarnings: settingsWarnings, gate: gate)
    }
}

struct ErrorEnvelope: Decodable {
    var error: String? = nil; var message: String? = nil; var code: String? = nil; var details: JSONValue? = nil; var requestId: String? = nil; var documentationURL: String? = nil
    enum CodingKeys: String, CodingKey { case error, message, code, details; case requestId = "request_id"; case documentationURL = "documentation_url" }
}
private func jsonObject<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
