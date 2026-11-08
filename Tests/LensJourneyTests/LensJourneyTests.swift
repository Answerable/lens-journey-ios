import XCTest
@testable import LensJourney

final class LensJourneyTests: XCTestCase {
    func testDecodesEveryEvaluateFixtureAndCapturedResponses() throws {
        for name in fixtureNames(prefix: "evaluate-") {
            let fixture = try loadFixture(name)
            if fixture.response.status == 200 { _ = try JSONDecoder().decode(JourneyState.self, from: try fixture.response.body.encoded()) }
            else { _ = try JSONDecoder().decode(JSONValue.self, from: try fixture.response.body.encoded()) }
        }
        // The captured server output: `subtotal` is the decimal STRING "45000.00", `confidence` is the string "high".
        let configuration = try loadFixture("configurations-201-captured.json")
        XCTAssertEqual(configuration.response.status, 201)
        let decoded = try JSONDecoder().decode(LensConfiguration.self, from: try configuration.response.body.encoded())
        XCTAssertEqual(decoded.subtotal, Decimal(string: "45000.00"))
        XCTAssertEqual(decoded.subtotalPaise, 4_500_000)
        XCTAssertEqual(decoded.currency, "INR")
        let ocr = try loadFixture("rx-ocr-200-captured.json")
        XCTAssertEqual(try JSONDecoder().decode(OCRResponse.self, from: try ocr.response.body.encoded()).prescription.confidence, .high)
        let low = try loadFixture("rx-ocr-200-low-confidence-captured.json")
        XCTAssertEqual(try JSONDecoder().decode(OCRResponse.self, from: try low.response.body.encoded()).prescription.confidence, .low)
    }

    func testConfidenceIsTolerantOfValuesTheServerMayAddLater() throws {
        func decode(_ confidence: String) throws -> OCRConfidence? {
            let body = "{\"od\":{},\"os\":{},\"confidence\":\(confidence)}"
            return try JSONDecoder().decode(Prescription.self, from: Data(body.utf8)).confidence
        }
        XCTAssertEqual(try decode("\"medium\""), .unknown)
        XCTAssertEqual(try decode("0.9"), .unknown)
        XCTAssertNil(try JSONDecoder().decode(Prescription.self, from: Data("{\"od\":{},\"os\":{}}".utf8)).confidence)
        // A confirmed draft is sent back as `prescription`: a named confidence travels, an unknown one is not made up on the wire.
        let named = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Prescription(od: EyePrescription(), os: EyePrescription(), confidence: .low))) as? [String: Any]
        XCTAssertEqual(named?["confidence"] as? String, "low")
        let unknown = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Prescription(od: EyePrescription(), os: EyePrescription(), confidence: .unknown))) as? [String: Any]
        XCTAssertNil(unknown?["confidence"])
    }

    func testSubtotalDecodesFromADecimalStringOrANumberAndRejectsGarbage() throws {
        func decode(_ subtotal: String) throws -> LensConfiguration {
            let body = "{\"id\":\"x\",\"subtotal\":\(subtotal),\"breakdown\":[],\"inherited_from_partner\":false,\"prescription_on_file\":false}"
            return try JSONDecoder().decode(LensConfiguration.self, from: Data(body.utf8))
        }
        XCTAssertEqual(try decode("\"1234.50\"").subtotal, Decimal(string: "1234.50"))
        XCTAssertEqual(try decode("120").subtotal, Decimal(120))
        XCTAssertNil(try decode("null").subtotal)
        XCTAssertThrowsError(try decode("\"free\""))
        let absent = try JSONDecoder().decode(LensConfiguration.self, from: Data("{\"id\":\"x\",\"breakdown\":[],\"inherited_from_partner\":false,\"prescription_on_file\":false}".utf8))
        XCTAssertNil(absent.subtotal)
    }

    func testWholeJourneySendsCumulativePicksBackIsLocalAndFinishReusesIdempotencyKey() async throws {
        let transport = FixtureTransport(responses: [
            try fixtureResponse("evaluate-first-choice.json"),
            try fixtureResponse("evaluate-second-choice.json"),
            try fixtureResponse("evaluate-summary.json"),
            try fixtureResponse("evaluate-summary.json"),
            TransportResponse(status: 503, body: errorBody("EVALUATION_UNAVAILABLE")),
            try fixtureResponse("configurations-201-captured.json")
        ])
        let journey = LensJourney(config: try JourneyConfig(sessionId: "fixture-session-0001", clientId: "client_12345"), transport: transport)
        let first = try await journey.start(category: "single-vision", frame: FrameRef(sku: "FIXTURE-SKU"), vision: .distance)
        XCTAssertEqual(first.step?.id, "vision-option")
        _ = try await journey.select(optionId: "anti-reflective")
        _ = try await journey.select(optionId: "opt-anti-reflective-150-stock")
        let countBeforeBack = await transport.requests.count
        let backed = try await journey.back()
        let countAfterBack = await transport.requests.count
        XCTAssertEqual(countAfterBack, countBeforeBack)
        XCTAssertEqual(backed.step?.id, "ar-index")
        _ = try await journey.select(optionId: "opt-anti-reflective-150-stock")
        let configuration = try await journey.finish()
        XCTAssertEqual(configuration.id, "00000000-0000-4000-8000-000000000001")
        XCTAssertEqual(configuration.subtotal, Decimal(string: "45000.00"))

        let requests = await transport.requests
        let secondBody = try jsonObject(requests[1].body)
        XCTAssertEqual(((secondBody["selections"] as? [String: Any])?["vision-option"] as? [String])?.first, "anti-reflective")
        let thirdSelections = try XCTUnwrap(jsonObject(requests[2].body)["selections"] as? [String: Any])
        XCTAssertEqual((thirdSelections["ar-index"] as? [String])?.first, "opt-anti-reflective-150-stock")
        let finishBodies = try requests.suffix(2).map { try jsonObject($0.body) }
        XCTAssertEqual(finishBodies[0]["idempotency_key"] as? String, finishBodies[1]["idempotency_key"] as? String)
        XCTAssertEqual((finishBodies[1]["selections"] as? [[String: String]])?.count, 2)
        XCTAssertEqual(finishBodies[1]["session_id"] as? String, "fixture-session-0001")
        // The frame SKU goes where POST /configurations reads it (product_sku), not only in a `frame` object it ignores.
        XCTAssertEqual(finishBodies[1]["product_sku"] as? String, "FIXTURE-SKU")
        XCTAssertNil(finishBodies[1]["product_id"])
    }

    func testViolationsAndPrescriptionErrorsAreSurfaced() throws {
        let violation = try decodeJourney("evaluate-violation-off-path.json")
        XCTAssertEqual(violation.violations.first?.code, "SELECTION_OFF_PATH")
        let rx = try decodeJourney("evaluate-prescription-out-of-range.json")
        XCTAssertEqual(rx.prescription?.errors.map(\.code), ["SPH_OUT_OF_RANGE", "RX_INCOMPLETE"])
    }

    func testEveryStatusMapsAndOnlyRetryableStatusesRetryOnce() async throws {
        let cases: [(Int, String, LensJourneyError.Kind)] = [
            (400, "INVALID_REQUEST", .invalidRequest), (401, "INVALID_API_KEY", .unauthorized),
            (403, "INSUFFICIENT_SCOPE", .insufficientScope), (404, "WORKFLOW_NOT_PUBLISHED", .workflowNotPublished),
            (413, "PAYLOAD_TOO_LARGE", .payloadTooLarge), (415, "UNSUPPORTED_MEDIA_TYPE", .unsupportedMediaType),
            (422, "PRICE_UNAVAILABLE", .unprocessable), (429, "RATE_LIMITED", .rateLimited),
            (503, "EVALUATION_UNAVAILABLE", .unavailable)
        ]
        for (status, code, kind) in cases {
            let headers = status == 429 ? ["Retry-After": "0"] : [:]
            let responses = Array(repeating: TransportResponse(status: status, headers: headers, body: errorBody(code)), count: status == 429 || status == 503 ? 2 : 1)
            let transport = FixtureTransport(responses: responses)
            let journey = LensJourney(config: try JourneyConfig(clientId: "client_12345"), transport: transport, sleep: { _ in })
            do { _ = try await journey.start(category: "single-vision", frame: nil, vision: .distance); XCTFail("Expected \(status)") }
            catch let error as LensJourneyError { XCTAssertEqual(error.kind, kind); XCTAssertEqual(error.code, code) }
            let requestCount = await transport.requests.count
            XCTAssertEqual(requestCount, status == 429 || status == 503 ? 2 : 1)
        }
    }

    func testRetryAfterSecondsAreHonoured() async throws {
        let delays = DelayRecorder()
        let transport = FixtureTransport(responses: [
            TransportResponse(status: 429, headers: ["retry-after": "2"], body: errorBody("RATE_LIMITED")),
            TransportResponse(status: 429, headers: ["retry-after": "9"], body: errorBody("RATE_LIMITED"))
        ])
        let journey = LensJourney(config: try JourneyConfig(clientId: "client_12345"), transport: transport, sleep: { value in await delays.record(value) })
        do { _ = try await journey.start(category: "single-vision", frame: nil, vision: .distance); XCTFail("Expected rate limit") } catch { }
        let recorded = await delays.values
        XCTAssertEqual(recorded, [2_000_000_000])
    }

    func testDefaultSleeperRetries503WithRealTaskSleep() async throws {
        let transport = FixtureTransport(responses: [TransportResponse(status: 503, body: errorBody("DOWN")), choiceResponse()])
        let journey = LensJourney(config: try JourneyConfig(clientId: "client_12345"), transport: transport)
        let started = Date()
        let state = try await journey.start(category: "same", frame: nil, vision: .distance)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.09)
        XCTAssertEqual(state.step?.id, "node")
        let requestCount = await transport.requests.count
        XCTAssertEqual(requestCount, 2)
    }

    func testNetworkErrorsAreTypedAndNotRetried() async throws {
        let transport = FixtureTransport(error: URLError(.notConnectedToInternet))
        let journey = LensJourney(config: try JourneyConfig(clientId: "client_12345"), transport: transport)
        do { _ = try await journey.start(category: "single-vision", frame: nil, vision: .distance); XCTFail("Expected network error") }
        catch let error as LensJourneyError { XCTAssertEqual(error.kind, .network) }
        let requestCount = await transport.requests.count
        XCTAssertEqual(requestCount, 1)
    }

    func testCancellationIsNotWrappedAsNetwork() async throws {
        for error in [CancellationError() as Error, URLError(.cancelled) as Error] {
            let journey = LensJourney(config: try JourneyConfig(clientId: "client_12345"), transport: FixtureTransport(error: error))
            do { _ = try await journey.start(category: "same", frame: nil, vision: .distance); XCTFail("Expected cancellation") }
            catch let url as URLError { XCTAssertEqual(url.code, .cancelled) }
            catch is CancellationError { }
            catch { XCTFail("Cancellation was wrapped: \(error)") }
        }
    }

    func testBusyRejectsOverlappingOperation() async throws {
        let transport = BlockingTransport(response: choiceResponse())
        let journey = LensJourney(config: try JourneyConfig(clientId: "client_12345"), transport: transport)
        let first = Task { try await journey.start(category: "same", frame: nil, vision: .distance) }
        await transport.waitUntilEntered()
        do { _ = try await journey.start(category: "other", frame: nil, vision: .distance); XCTFail("Expected busy") }
        catch let error as LensJourneyError { XCTAssertEqual(error.kind, .busy) }
        await transport.release()
        _ = try await first.value
    }

    func testInvalidAndFailedSelectionLeavePicksAndHistoryUnchanged() async throws {
        let choice = choiceResponse(options: ["one", "two", "disabled"])
        let transport = FixtureTransport(responses: [choice, choice, TransportResponse(status: 503, body: errorBody("DOWN")), TransportResponse(status: 503, body: errorBody("DOWN")), choice])
        let journey = LensJourney(config: try JourneyConfig(clientId: "client_12345"), transport: transport, sleep: { _ in })
        _ = try await journey.start(category: "same", frame: nil, vision: .distance)
        _ = try await journey.select(optionId: "one")
        do { _ = try await journey.select(optionId: "disabled"); XCTFail("Expected invalid selection") }
        catch let error as LensJourneyError { XCTAssertEqual(error.kind, .invalidSelection) }
        let countAfterInvalid = await transport.requests.count
        XCTAssertEqual(countAfterInvalid, 2)
        do { _ = try await journey.select(optionId: "two"); XCTFail("Expected failure") } catch { }
        _ = try await journey.select(optionId: "two")
        let requestsAfterFailure = await transport.requests
        let body = try jsonObject(requestsAfterFailure.last?.body)
        XCTAssertEqual((body["selections"] as? [String: [String]])?["node"], ["two"])
    }

    func testFinishRequiresSummaryWithoutRequest() async throws {
        let transport = FixtureTransport(responses: [choiceResponse(), choiceResponse()])
        let journey = LensJourney(config: try JourneyConfig(clientId: "client_12345"), transport: transport)
        _ = try await journey.start(category: "same", frame: nil, vision: .distance)
        _ = try await journey.select(optionId: "one")
        do { _ = try await journey.finish(); XCTFail("Expected incomplete") }
        catch let error as LensJourneyError { XCTAssertEqual(error.kind, .journeyIncomplete) }
        let requestCount = await transport.requests.count
        XCTAssertEqual(requestCount, 2)
    }

    func testStartKeepsPrescriptionForSameCategoryAndClearsForNewCategory() async throws {
        let transport = FixtureTransport(responses: [choiceResponse(), choiceResponse(), summaryResponse(), summaryResponse()])
        let journey = LensJourney(config: try JourneyConfig(clientId: "client_12345"), transport: transport)
        let rx = Prescription(od: EyePrescription(sph: .number(1)), os: EyePrescription(sph: .number(1)))
        _ = try await journey.setPrescription(rx)
        _ = try await journey.start(category: "same", frame: nil, vision: .distance)
        _ = try await journey.select(optionId: "one")
        _ = try await journey.start(category: "same", frame: nil, vision: .distance)
        _ = try await journey.start(category: "new", frame: nil, vision: .distance)
        let startRequests = await transport.requests
        let bodies = try startRequests.map { try jsonObject($0.body) }
        XCTAssertNotNil(bodies[0]["prescription"]); XCTAssertNotNil(bodies[2]["prescription"]); XCTAssertNil(bodies[3]["prescription"])
        XCTAssertTrue((bodies[2]["selections"] as? [String: [String]])?.isEmpty == true)
    }

    func testRetryAfterParsingClampingAndDefaults() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        let cases: [(String, UInt64)] = [("5", 5_000_000_000), ("999999999999999999999", 1_000_000_000), ("garbage", 1_000_000_000), ("-3", 1_000_000_000), (formatter.string(from: now.addingTimeInterval(5)), 5_000_000_000)]
        for (header, expected) in cases {
            let delays = DelayRecorder()
            let transport = FixtureTransport(responses: [TransportResponse(status: 429, headers: ["Retry-After": header], body: errorBody("RATE")), summaryResponse()])
            let journey = LensJourney(config: try JourneyConfig(clientId: "client_12345"), transport: transport, sleep: { await delays.record($0) }, clock: { now })
            _ = try await journey.start(category: "same", frame: nil, vision: .distance)
            let recorded = await delays.values
            XCTAssertEqual(recorded, [expected], header)
        }
    }

    func testScanReturnsUnconfirmedDraftWithoutChangingRouting() async throws {
        let transport = FixtureTransport(responses: [try fixtureResponse("rx-ocr-200-captured.json"), try fixtureResponse("evaluate-first-choice.json")])
        let journey = LensJourney(config: try JourneyConfig(clientId: "client_12345"), transport: transport)
        let draft = try await journey.scanPrescription(photo: Data(validJPEGPrefix), preparer: PassThroughPreparer())
        XCTAssertFalse(draft.confirmed)
        _ = try await journey.start(category: "single-vision", frame: nil, vision: .distance)
        let requests = await transport.requests
        let startBody = try jsonObject(requests[1].body)
        XCTAssertNil(startBody["prescription"])
    }

    func testClientIdValidationAndGeneration() throws {
        XCTAssertThrowsError(try JourneyConfig(clientId: "bad id!"))
        let generated = try JourneyConfig().clientId
        XCTAssertTrue(generated.range(of: "^[A-Za-z0-9_-]{8,64}$", options: .regularExpression) != nil)
    }

    func testEvaluateBodyLimitFailsBeforeTransport() async throws {
        let transport = FixtureTransport(responses: [])
        let journey = LensJourney(config: try JourneyConfig(clientId: "client_12345", currency: String(repeating: "x", count: 17_000)), transport: transport)
        do { _ = try await journey.start(category: "single-vision", frame: nil, vision: .distance); XCTFail("Expected local limit") }
        catch let error as LensJourneyError { XCTAssertEqual(error.kind, .requestTooLarge) }
        let requestCount = await transport.requests.count
        XCTAssertEqual(requestCount, 0)
    }

    func testSelectionIdAndPerNodeLimitsFailBeforeTransport() async throws {
        let firstTransport = FixtureTransport(responses: [try fixtureResponse("evaluate-first-choice.json")])
        let firstJourney = LensJourney(config: try JourneyConfig(clientId: "client_12345"), transport: firstTransport)
        _ = try await firstJourney.start(category: "single-vision", frame: nil, vision: .distance)
        do { _ = try await firstJourney.select(optionId: String(repeating: "x", count: 129)); XCTFail("Expected id limit") }
        catch let error as LensJourneyError { XCTAssertEqual(error.kind, .invalidRequest) }
        let firstCount = await firstTransport.requests.count
        XCTAssertEqual(firstCount, 1)

        let multipleOptions = (0...17).map { "{\"id\":\"option-\($0)\",\"label\":\"Option\",\"enabled\":true,\"recommended\":false}" }.joined(separator: ",")
        let multiple = TransportResponse(status: 200, body: Data("{\"workflow_version\":\"1\",\"category\":\"x\",\"terminal\":\"choice\",\"step\":{\"id\":\"multi\",\"type\":\"choice\",\"label\":\"Multi\",\"selection_mode\":\"multiple\",\"options\":[\(multipleOptions)]},\"selections\":{},\"auto_selected\":[],\"violations\":[],\"settings_warnings\":[]}".utf8))
        let multipleTransport = FixtureTransport(responses: Array(repeating: multiple, count: 17))
        let multipleJourney = LensJourney(config: try JourneyConfig(clientId: "client_12345"), transport: multipleTransport)
        _ = try await multipleJourney.start(category: "x", frame: nil, vision: .distance)
        for index in 0..<16 { _ = try await multipleJourney.select(optionId: "option-\(index)") }
        do { _ = try await multipleJourney.select(optionId: "option-17"); XCTFail("Expected per-node limit") }
        catch let error as LensJourneyError { XCTAssertEqual(error.kind, .invalidRequest) }
        let multipleCount = await multipleTransport.requests.count
        XCTAssertEqual(multipleCount, 17)
    }

    func testUnknownFieldsAndEnumValuesAreTolerated() throws {
        let data = Data(#"{"workflow_version":"1","category":"x","terminal":"future","step":{"id":"n","type":"future","label":"L","selection_mode":"future","options":[]},"selections":{},"auto_selected":[],"violations":[],"settings_warnings":[],"gate":{"decision":"future","degraded":false,"reason":"x"},"new_field":true}"#.utf8)
        let state = try JSONDecoder().decode(JourneyState.self, from: data)
        XCTAssertEqual(state.terminal, .unknown)
        XCTAssertEqual(state.step?.type, .unknown)
        XCTAssertEqual(state.step?.selectionMode, .unknown)
        XCTAssertEqual(state.gate?.decision, .unknown)
    }

    func testEvaluateRequestsMatchTheSharedFixtureRequests() async throws {
        let names = ["evaluate-first-choice.json", "evaluate-second-choice.json", "evaluate-summary.json"]
        let first = try loadFixture(names[0]).request.body
        guard case .object(let firstBody) = first else { return XCTFail("fixture body is not an object") }
        let rx = try JSONDecoder().decode(Prescription.self, from: try XCTUnwrap(firstBody["prescription"]).encoded())
        let frame = try JSONDecoder().decode(FrameRef.self, from: try XCTUnwrap(firstBody["frame"]).encoded())
        guard case .scalar(.string(let category)) = try XCTUnwrap(firstBody["category"]) else { return XCTFail("category is not a string") }
        let transport = FixtureTransport(responses: try names.map { try fixtureResponse($0) })
        let journey = LensJourney(config: try JourneyConfig(sessionId: "session-12345678", clientId: "client_12345"), transport: transport)
        _ = try await journey.setPrescription(rx)
        _ = try await journey.start(category: category, frame: frame, vision: .distance)
        _ = try await journey.select(optionId: "anti-reflective")
        _ = try await journey.select(optionId: "opt-anti-reflective-150-stock")

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
        for (index, name) in names.enumerated() {
            let expected = try loadFixture(name).request
            let sent = requests[index]
            XCTAssertEqual(sent.method, "POST", name)
            XCTAssertEqual(sent.path, "/api/v1/lens-journey" + expected.path, name)
            XCTAssertEqual(sent.contentType, "application/json", name)
            XCTAssertEqual(sent.headers["X-Client-Id"], "client_12345", name)
            var sentBody = try jsonObject(sent.body)
            // The one documented difference: the SDK always states vision_type, the captured fixtures predate it.
            XCTAssertEqual(sentBody.removeValue(forKey: "vision_type") as? String, "distance", name)
            let expectedBody = try XCTUnwrap(JSONSerialization.jsonObject(with: expected.body.encoded()) as? [String: Any])
            XCTAssertTrue((sentBody as NSDictionary).isEqual(to: expectedBody), "\(name): sent \(sentBody) expected \(expectedBody)")
        }
    }

    func testFinishReusesOneIdempotencyKeyAcrossRepeatedCallsUntilTheSelectionsChange() async throws {
        let offline = ScriptStep.failure(URLError(.notConnectedToInternet))
        let down = ScriptStep.response(TransportResponse(status: 503, body: errorBody("EVALUATION_UNAVAILABLE")))
        let transport = ScriptedTransport([
            .response(choiceResponse(options: ["one", "two"])), .response(summaryResponse()),
            offline, down, down, .response(try fixtureResponse("configurations-201-captured.json")),
            .response(summaryResponse()), .response(try fixtureResponse("configurations-201-captured.json"))
        ])
        let journey = LensJourney(config: try JourneyConfig(clientId: "client_12345"), transport: transport, sleep: { _ in })
        _ = try await journey.start(category: "same", frame: nil, vision: .distance)
        _ = try await journey.select(optionId: "one")
        do { _ = try await journey.finish(); XCTFail("Expected network error") } catch let error as LensJourneyError { XCTAssertEqual(error.kind, .network) }
        do { _ = try await journey.finish(); XCTFail("Expected 503") } catch let error as LensJourneyError { XCTAssertEqual(error.kind, .unavailable) }
        _ = try await journey.finish()
        _ = try await journey.back()
        _ = try await journey.select(optionId: "two")
        _ = try await journey.finish()

        let keys = try await transport.configurationKeys()
        XCTAssertEqual(keys.count, 5)
        XCTAssertEqual(Set(keys.prefix(4)).count, 1, "the key must survive failed finish calls: \(keys)")
        XCTAssertNotEqual(keys[0], keys[4])
    }

    func testFinishAfterSetPrescriptionUsesANewIdempotencyKey() async throws {
        let transport = ScriptedTransport([
            .response(choiceResponse()), .response(summaryResponse()), .failure(URLError(.notConnectedToInternet)),
            .response(summaryResponse()), .response(try fixtureResponse("configurations-201-captured.json"))
        ])
        let journey = LensJourney(config: try JourneyConfig(clientId: "client_12345"), transport: transport)
        _ = try await journey.start(category: "same", frame: nil, vision: .distance)
        _ = try await journey.select(optionId: "one")
        do { _ = try await journey.finish(); XCTFail("Expected network error") } catch let error as LensJourneyError { XCTAssertEqual(error.kind, .network) }
        _ = try await journey.setPrescription(Prescription(od: EyePrescription(sph: .number(1)), os: EyePrescription(sph: .number(1))))
        _ = try await journey.finish()

        let keys = try await transport.configurationKeys()
        XCTAssertEqual(keys.count, 2)
        XCTAssertNotEqual(keys[0], keys[1])
    }

    func testFinishAfterAFreshStartAndSelectionUsesANewIdempotencyKey() async throws {
        let transport = ScriptedTransport([
            .response(choiceResponse()), .response(summaryResponse()), .failure(URLError(.notConnectedToInternet)),
            .response(choiceResponse()), .response(summaryResponse()), .response(try fixtureResponse("configurations-201-captured.json"))
        ])
        let journey = LensJourney(config: try JourneyConfig(clientId: "client_12345"), transport: transport)
        _ = try await journey.start(category: "same", frame: nil, vision: .distance)
        _ = try await journey.select(optionId: "one")
        do { _ = try await journey.finish(); XCTFail("Expected network error") } catch let error as LensJourneyError { XCTAssertEqual(error.kind, .network) }
        _ = try await journey.start(category: "same", frame: nil, vision: .distance)
        _ = try await journey.select(optionId: "one")
        _ = try await journey.finish()

        let keys = try await transport.configurationKeys()
        XCTAssertEqual(keys.count, 2)
        XCTAssertNotEqual(keys[0], keys[1])
    }

    func testBackAfterSetPrescriptionRestoresTheStateThatMatchesTheRemainingSelections() async throws {
        let transport = FixtureTransport(responses: [
            choiceResponse(options: ["one", "two"]), summaryResponse(), summaryResponse(rxComplete: true), summaryResponse(),
            try fixtureResponse("configurations-201-captured.json")
        ])
        let journey = LensJourney(config: try JourneyConfig(clientId: "client_12345"), transport: transport)
        _ = try await journey.start(category: "same", frame: nil, vision: .distance)
        _ = try await journey.select(optionId: "one")
        _ = try await journey.setPrescription(Prescription(od: EyePrescription(sph: .number(1)), os: EyePrescription(sph: .number(1))))

        let callsBefore = await transport.requests.count
        let back = try await journey.back()
        let callsAfter = await transport.requests.count
        XCTAssertEqual(callsAfter, callsBefore)
        XCTAssertEqual(back.terminal, .choice)
        XCTAssertEqual(back.step?.id, "node")
        XCTAssertEqual(back.prescription?.complete, true, "the prescription check follows the current prescription")
        // Nothing is selected any more, so there is nothing to finish.
        do { _ = try await journey.finish(); XCTFail("Expected incomplete") } catch let error as LensJourneyError { XCTAssertEqual(error.kind, .journeyIncomplete) }

        _ = try await journey.select(optionId: "two")
        _ = try await journey.finish()
        let requests = await transport.requests
        let evaluate = try jsonObject(requests[3].body)
        XCTAssertEqual(evaluate["selections"] as? [String: [String]], ["node": ["two"]])
        XCTAssertNotNil(evaluate["prescription"])
        let finishBody = try jsonObject(requests[4].body)
        XCTAssertEqual(finishBody["selections"] as? [[String: String]], [["node_id": "node", "option_id": "two"]])
    }

    func testBackRestoresExactlyThePicksThatMatchedTheEarlierState() async throws {
        let transport = FixtureTransport(responses: [
            choiceResponse(options: ["a1"], node: "a"), choiceResponse(options: ["b1", "b2"], node: "b", mode: "multiple"), summaryResponse(), summaryResponse()
        ])
        let journey = LensJourney(config: try JourneyConfig(clientId: "client_12345"), transport: transport)
        _ = try await journey.start(category: "same", frame: nil, vision: .distance)
        _ = try await journey.select(optionId: "a1")
        _ = try await journey.select(optionId: "b1")
        let back = try await journey.back()
        XCTAssertEqual(back.step?.id, "b")
        _ = try await journey.select(optionId: "b2")
        let requests = await transport.requests
        XCTAssertEqual(try jsonObject(requests[3].body)["selections"] as? [String: [String]], ["a": ["a1"], "b": ["b2"]])
    }

    func testBackWithNothingToUndoIsAnInvalidRequestBeforeStartRightAfterStartAndAfterUndoingEverything() async throws {
        let transport = FixtureTransport(responses: [choiceResponse(), summaryResponse()])
        let journey = LensJourney(config: try JourneyConfig(clientId: "client_12345"), transport: transport)
        func assertNothingToUndo(_ label: String) async {
            do { _ = try await journey.back(); XCTFail("Expected invalid request \(label)") }
            catch let error as LensJourneyError {
                XCTAssertEqual(error.kind, .invalidRequest, label)
                XCTAssertEqual(error.code, "INVALID_REQUEST", label)
                XCTAssertEqual(error.message, "There is no previous selection", label)
            } catch { XCTFail("Unexpected error \(error) \(label)") }
        }
        await assertNothingToUndo("before start")
        _ = try await journey.start(category: "same", frame: nil, vision: .distance)
        await assertNothingToUndo("right after start")
        _ = try await journey.select(optionId: "one")
        let back = try await journey.back()
        XCTAssertEqual(back.step?.id, "node")
        await assertNothingToUndo("after undoing everything")
        let requestCount = await transport.requests.count
        XCTAssertEqual(requestCount, 2)
    }

    func testA400InvalidClientIdMapsToTheTypedErrorAndIsNeverRetried() async throws {
        let transport = FixtureTransport(responses: [try fixtureResponse("evaluate-400-bad-client-id.json")])
        let journey = LensJourney(config: try JourneyConfig(clientId: "client_12345"), transport: transport)
        do { _ = try await journey.start(category: "single-vision", frame: nil, vision: .distance); XCTFail("Expected invalid client id") }
        catch let error as LensJourneyError {
            XCTAssertEqual(error.kind, .invalidClientId)
            XCTAssertEqual(error.code, "INVALID_CLIENT_ID")
        }
        let requestCount = await transport.requests.count
        XCTAssertEqual(requestCount, 1)
    }

    // MARK: Release gates: the nil (Task.sleep) sleeper

    func testDefaultSleeperRetries429WithRealTaskSleep() async throws {
        let transport = FixtureTransport(responses: [TransportResponse(status: 429, headers: ["Retry-After": "1"], body: errorBody("RATE_LIMITED")), choiceResponse()])
        let journey = LensJourney(config: try JourneyConfig(clientId: "client_12345"), transport: transport)
        let started = Date()
        let state = try await journey.start(category: "same", frame: nil, vision: .distance)
        let elapsed = Date().timeIntervalSince(started)
        // Task.sleep never returns early, so the lower bound holds on any machine; the generous upper bound only catches a stuck sleep.
        XCTAssertGreaterThanOrEqual(elapsed, 0.9, "Retry-After: 1 must wait on the real clock")
        XCTAssertLessThan(elapsed, 30, "the retry must not hang")
        XCTAssertEqual(state.step?.id, "node")
        let requestCount = await transport.requests.count
        XCTAssertEqual(requestCount, 2)
    }

    /// The nil (Task.sleep) path: the call is cancelled as soon as the first response is in. Whether the cancel lands just before or inside
    /// the 30 second `Task.sleep`, the outcome is the same, so no fixed delay is needed. The injected-sleeper test below pins "inside".
    func testCancellingTheNilSleeperPathNeverSendsTheRetryAndFreesTheJourney() async throws {
        let transport = FixtureTransport(responses: [TransportResponse(status: 429, headers: ["Retry-After": "30"], body: errorBody("RATE_LIMITED")), choiceResponse()])
        let journey = LensJourney(config: try JourneyConfig(clientId: "client_12345"), transport: transport)
        let task = Task { try await journey.start(category: "same", frame: nil, vision: .distance) }
        for _ in 0..<500 { if await transport.requests.count >= 1 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let cancelledAt = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        catch { XCTFail("Cancellation was wrapped: \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 5, "the sleep must be interruptible")
        let afterCancel = await transport.requests.count
        XCTAssertEqual(afterCancel, 1, "a cancelled call must not send the retry")
        // The operation lock was released: the next call goes through.
        _ = try await journey.start(category: "same", frame: nil, vision: .distance)
        let afterNext = await transport.requests.count
        XCTAssertEqual(afterNext, 2)
    }

    /// Cancels only after the call has provably entered a real `Task.sleep`: the injected sleeper signals, then sleeps for real.
    func testCancellingInsideARealTaskSleepNeverSendsTheRetry() async throws {
        let transport = FixtureTransport(responses: [TransportResponse(status: 503, body: errorBody("DOWN")), choiceResponse()])
        let entered = expectation(description: "the retry sleep has started")
        let journey = LensJourney(config: try JourneyConfig(clientId: "client_12345"), transport: transport, sleep: { _ in
            entered.fulfill()
            try await Task.sleep(nanoseconds: 30_000_000_000)
        })
        let task = Task { try await journey.start(category: "same", frame: nil, vision: .distance) }
        await fulfillment(of: [entered], timeout: 10)
        let cancelledAt = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        catch { XCTFail("Cancellation was wrapped: \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 5, "the sleep must be interruptible")
        let afterCancel = await transport.requests.count
        XCTAssertEqual(afterCancel, 1, "a cancelled call must not send the retry")
        _ = try await journey.start(category: "same", frame: nil, vision: .distance)
        let afterNext = await transport.requests.count
        XCTAssertEqual(afterNext, 2)
    }

    // MARK: Follow-ups

    func testScanTakesTheOperationLockInBothDirectionsAndReleasesItOnFailure() async throws {
        let transport = BlockingTransport(response: try fixtureResponse("rx-ocr-200-captured.json"))
        let journey = LensJourney(config: try JourneyConfig(clientId: "client_12345"), transport: transport)
        let scan = Task { try await journey.scanPrescription(photo: Data(validJPEGPrefix), preparer: PassThroughPreparer()) }
        await transport.waitUntilEntered()
        do { _ = try await journey.start(category: "same", frame: nil, vision: .distance); XCTFail("Expected busy during a scan") }
        catch let error as LensJourneyError { XCTAssertEqual(error.kind, .busy) }
        do { _ = try await journey.scanPrescription(photo: Data(validJPEGPrefix), preparer: PassThroughPreparer()); XCTFail("Expected busy for a second scan") }
        catch let error as LensJourneyError { XCTAssertEqual(error.kind, .busy) }
        await transport.release()
        _ = try await scan.value

        // A scan rejected before any request still frees the lock.
        let next = FixtureTransport(responses: [choiceResponse()])
        let second = LensJourney(config: try JourneyConfig(clientId: "client_12345"), transport: next)
        do { _ = try await second.scanPrescription(photo: Data(), preparer: PassThroughPreparer()); XCTFail("Expected empty photo to fail") }
        catch let error as LensJourneyError { XCTAssertEqual(error.kind, .payloadTooLarge) }
        _ = try await second.start(category: "same", frame: nil, vision: .distance)

        // A start in flight rejects a scan.
        let blocked = BlockingTransport(response: choiceResponse())
        let third = LensJourney(config: try JourneyConfig(clientId: "client_12345"), transport: blocked)
        let start = Task { try await third.start(category: "same", frame: nil, vision: .distance) }
        await blocked.waitUntilEntered()
        do { _ = try await third.scanPrescription(photo: Data(validJPEGPrefix), preparer: PassThroughPreparer()); XCTFail("Expected busy during a start") }
        catch let error as LensJourneyError { XCTAssertEqual(error.kind, .busy) }
        await blocked.release()
        _ = try await start.value
    }

    func testMalformedSuccessBodiesAreATypedErrorOnEvaluateFinishAndScanAndLeaveStateUnchanged() async throws {
        let bad = [Data("not json".utf8), Data("{\"terminal\": 5}".utf8), Data()]
        for body in bad {
            let transport = FixtureTransport(responses: [TransportResponse(status: 200, body: body), choiceResponse()])
            let journey = LensJourney(config: try JourneyConfig(clientId: "client_12345"), transport: transport)
            do { _ = try await journey.start(category: "same", frame: nil, vision: .distance); XCTFail("Expected a typed error") }
            catch let error as LensJourneyError { XCTAssertEqual(error.kind, .malformedResponse); XCTAssertEqual(error.code, "MALFORMED_RESPONSE") }
            // Nothing was committed and the lock is free: the next start works.
            let state = try await journey.start(category: "same", frame: nil, vision: .distance)
            XCTAssertEqual(state.step?.id, "node")
        }

        let finishTransport = FixtureTransport(responses: [choiceResponse(), summaryResponse(), TransportResponse(status: 201, body: Data("[]".utf8))])
        let finishing = LensJourney(config: try JourneyConfig(clientId: "client_12345"), transport: finishTransport)
        _ = try await finishing.start(category: "same", frame: nil, vision: .distance)
        _ = try await finishing.select(optionId: "one")
        do { _ = try await finishing.finish(); XCTFail("Expected a typed error") }
        catch let error as LensJourneyError { XCTAssertEqual(error.kind, .malformedResponse); XCTAssertEqual(error.code, "MALFORMED_RESPONSE") }

        let scanTransport = FixtureTransport(responses: [TransportResponse(status: 200, body: Data("{\"prescription\": 1}".utf8))])
        let scanning = LensJourney(config: try JourneyConfig(clientId: "client_12345"), transport: scanTransport)
        do { _ = try await scanning.scanPrescription(photo: Data(validJPEGPrefix), preparer: PassThroughPreparer()); XCTFail("Expected a typed error") }
        catch let error as LensJourneyError { XCTAssertEqual(error.kind, .malformedResponse); XCTAssertEqual(error.code, "MALFORMED_RESPONSE") }
    }

    /// Canonical mapping shared with Android: an unlisted status is `.unavailable` (and is not retried), finish() without a
    /// completed journey is `.journeyIncomplete`, and select()/start-less calls without a step are `.invalidState`. Each carries a code.
    func testCanonicalErrorMappingForUnlistedStatusFinishWithNoPicksAndSelectWithNoStep() async throws {
        for status in [418, 500, 502, 504] {
            let transport = FixtureTransport(responses: [TransportResponse(status: status, body: errorBody("ODD"))])
            let journey = LensJourney(config: try JourneyConfig(clientId: "client_12345"), transport: transport, sleep: { _ in })
            do { _ = try await journey.start(category: "same", frame: nil, vision: .distance); XCTFail("Expected \(status)") }
            catch let error as LensJourneyError { XCTAssertEqual(error.kind, .unavailable, "\(status)"); XCTAssertEqual(error.code, "ODD") }
            let requestCount = await transport.requests.count
            XCTAssertEqual(requestCount, 1, "\(status) is not retried")
        }

        let empty = FixtureTransport()
        let journey = LensJourney(config: try JourneyConfig(clientId: "client_12345"), transport: empty)
        do { _ = try await journey.finish(); XCTFail("Expected incomplete") }
        catch let error as LensJourneyError { XCTAssertEqual(error.kind, .journeyIncomplete); XCTAssertEqual(error.code, "JOURNEY_INCOMPLETE") }
        do { _ = try await journey.select(optionId: "one"); XCTFail("Expected invalid state") }
        catch let error as LensJourneyError { XCTAssertEqual(error.kind, .invalidState); XCTAssertEqual(error.code, "INVALID_STATE") }
        let requestCount = await empty.requests.count
        XCTAssertEqual(requestCount, 0)
    }

    func testClientSideValidationFailuresCarryAnInvalidRequestCode() async throws {
        let journey = LensJourney(config: try JourneyConfig(clientId: "client_12345"), transport: FixtureTransport())
        do { _ = try await journey.start(category: String(repeating: "x", count: 101), frame: nil, vision: .distance); XCTFail("Expected invalid request") }
        catch let error as LensJourneyError { XCTAssertEqual(error.kind, .invalidRequest); XCTAssertEqual(error.code, "INVALID_REQUEST") }
    }

    func testFixtureTopLevelContractDrift() throws {
        let evaluateAllowed: Set<String> = ["success", "workflow_version", "category", "terminal", "step", "selections", "auto_selected", "violations", "prescription", "settings_warnings", "gate", "error", "message", "request_id", "documentation_url"]
        let configurationAllowed: Set<String> = ["success", "id", "lens_summary", "subtotal", "subtotal_paise", "subtotal_minor", "currency_decimals", "price_basis", "price_basis_note", "currency", "breakdown", "inherited_from_partner", "prescription_on_file", "photo_attached", "photo_attach_error", "photos", "error", "code", "details"]
        let ocrAllowed: Set<String> = ["success", "prescription", "provider", "prescription_id", "upload_capability", "error", "code"]
        for name in fixtureNames(prefix: nil) where name.hasSuffix(".json") {
            let fixture = try loadFixture(name)
            let keys = Set(try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.response.body.encoded()) as? [String: Any]).keys)
            let allowed = name.hasPrefix("evaluate-") ? evaluateAllowed : (name.hasPrefix("configurations-") ? configurationAllowed : ocrAllowed)
            XCTAssertTrue(keys.isSubset(of: allowed), "\(name) added unmapped keys: \(keys.subtracting(allowed))")
        }
    }
}

private struct Fixture: Decodable { let request: FixtureRequest; let response: FixtureResponse }
private struct FixtureRequest: Decodable { let path: String; let headers: [String: String]; let body: JSONValue }
private struct FixtureResponse: Decodable { let status: Int; let headers: [String: String?]; let body: JSONValue }

private actor FixtureTransport: Transport {
    private(set) var requests: [TransportRequest] = []
    private var responses: [TransportResponse]
    private let error: Error?
    init(responses: [TransportResponse] = [], error: Error? = nil) { self.responses = responses; self.error = error }
    func send(_ request: TransportRequest) async throws -> TransportResponse {
        requests.append(request)
        if let error { throw error }
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return responses.removeFirst()
    }
}
private enum ScriptStep { case response(TransportResponse), failure(Error) }
private actor ScriptedTransport: Transport {
    private(set) var requests: [TransportRequest] = []
    private var steps: [ScriptStep]
    init(_ steps: [ScriptStep]) { self.steps = steps }
    func send(_ request: TransportRequest) async throws -> TransportResponse {
        requests.append(request)
        guard !steps.isEmpty else { throw URLError(.badServerResponse) }
        switch steps.removeFirst() { case .response(let response): return response; case .failure(let error): throw error }
    }
    func configurationKeys() throws -> [String] {
        try requests.filter { $0.path.hasSuffix("/configurations") }.map { try XCTUnwrap(jsonObject($0.body)["idempotency_key"] as? String) }
    }
}
private actor DelayRecorder {
    private(set) var values: [UInt64] = []
    func record(_ value: UInt64) { values.append(value) }
}

private actor BlockingTransport: Transport {
    private let response: TransportResponse
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(response: TransportResponse) { self.response = response }
    func send(_ request: TransportRequest) async throws -> TransportResponse {
        // Only the first call blocks, so a regression that lets a second call through fails an assertion instead of hanging.
        guard !entered else { return response }
        entered = true
        await withCheckedContinuation { continuation = $0 }
        return response
    }
    func waitUntilEntered() async { while !entered { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}

private struct PassThroughPreparer: ImagePreparer {
    func prepare(_ image: Data) throws -> PreparedImage { PreparedImage(data: image, mimeType: "image/jpeg") }
}

private let validJPEGPrefix: [UInt8] = [0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0xff, 0xd9]

private func fixtureDirectory() -> URL {
    sdkFixturesDirectory()
}
private func fixtureNames(prefix: String?) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: fixtureDirectory().path)) ?? []
    return names.filter { prefix == nil || $0.hasPrefix(prefix!) }.sorted()
}
private func loadFixture(_ name: String) throws -> Fixture { try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureDirectory().appendingPathComponent(name))) }
private func fixtureResponse(_ name: String) throws -> TransportResponse {
    let response = try loadFixture(name).response
    return TransportResponse(status: response.status, headers: response.headers.compactMapValues { $0 }, body: try JSONEncoder().encode(response.body))
}
private func decodeJourney(_ name: String) throws -> JourneyState { try JSONDecoder().decode(JourneyState.self, from: loadFixture(name).response.body.encoded()) }
private func errorBody(_ code: String) -> Data { Data("{\"error\":\"\(code)\",\"message\":\"fixture\"}".utf8) }
private func jsonObject(_ data: Data?) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(data)) as? [String: Any]) }
private func choiceResponse(options: [String] = ["one"], node: String = "node", mode: String = "single") -> TransportResponse {
    let encoded = options.map { "{\"id\":\"\($0)\",\"label\":\"\($0)\",\"enabled\":\($0 == "disabled" ? "false" : "true"),\"recommended\":false}" }.joined(separator: ",")
    return TransportResponse(status: 200, body: Data("{\"workflow_version\":\"1\",\"category\":\"same\",\"terminal\":\"choice\",\"step\":{\"id\":\"\(node)\",\"type\":\"choice\",\"label\":\"Choice\",\"selection_mode\":\"\(mode)\",\"options\":[\(encoded)]},\"selections\":{},\"auto_selected\":[],\"violations\":[],\"settings_warnings\":[]}".utf8))
}
private func summaryResponse(rxComplete: Bool? = nil) -> TransportResponse {
    let rx = rxComplete.map { "\"prescription\":{\"complete\":\($0),\"errors\":[]}," } ?? ""
    return TransportResponse(status: 200, body: Data("{\"workflow_version\":\"1\",\"category\":\"same\",\"terminal\":\"summary\",\(rx)\"selections\":{},\"auto_selected\":[],\"violations\":[],\"settings_warnings\":[]}".utf8))
}
