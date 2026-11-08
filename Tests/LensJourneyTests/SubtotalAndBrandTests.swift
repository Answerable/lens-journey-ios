import XCTest
@testable import LensJourney

/// POST /configurations answers `subtotal` as a STRING at the currency's decimals, and catalogue markets add `subtotal_minor`,
/// `currency_decimals`, `price_basis` and `price_basis_note` (India keeps `subtotal_paise` and sends none of those).
/// These tests pin the real captured shapes, the exactness of the decimal, the typed malformed-response error, and the optional `brand`.
final class SubtotalAndBrandTests: XCTestCase {
    func testDecodesTheIndiaShapedStringSubtotalAndKeepsItsExactText() throws {
        let configuration = try decodeConfiguration(fixture: "configurations-201-captured.json")
        XCTAssertEqual(configuration.subtotal, Decimal(string: "45000.00"))
        XCTAssertEqual(configuration.subtotalString, "45000.00")
        XCTAssertEqual(configuration.currency, "INR")
        XCTAssertEqual(configuration.subtotalPaise, 4_500_000)
        // India sends none of the catalogue-market money fields: the ISO table is the fallback.
        XCTAssertNil(configuration.subtotalMinor); XCTAssertNil(configuration.currencyDecimals)
        XCTAssertNil(configuration.priceBasis); XCTAssertNil(configuration.priceBasisNote)
        XCTAssertFalse(configuration.isQuote)
        XCTAssertEqual(configuration.currencyMinorUnitDigits, 2)
        XCTAssertEqual(configuration.subtotalMinorUnits, 4_500_000)
    }

    func testDecodesANumericSubtotalToTheSameDecimalType() throws {
        let whole = try decode(configurationJSON(subtotal: "120"))
        XCTAssertEqual(whole.subtotal, Decimal(120))
        XCTAssertEqual(whole.subtotalString, "120")
        let fractional = try decode(configurationJSON(subtotal: "12.345", currency: "KWD"))
        XCTAssertEqual(fractional.subtotal, Decimal(string: "12.345"))
        XCTAssertEqual(fractional.subtotalString, "12.345")
        XCTAssertEqual(fractional.subtotalMinorUnits, 12_345)
    }

    func testKWDThreeDecimalSubtotalRoundTripsExactly() throws {
        let configuration = try decodeConfiguration(fixture: "configurations-201-kwd-captured.json")
        XCTAssertEqual(configuration.subtotal, Decimal(string: "22.345"))
        XCTAssertEqual(configuration.subtotalString, "22.345")
        XCTAssertEqual(configuration.currencyMinorUnitDigits, 3)
        XCTAssertEqual(configuration.subtotalMinorUnits, 22_345)
        // Beyond a Double's 15-16 significant digits the string must still be exact.
        let wide = try decode(configurationJSON(subtotal: "\"123456789012345.678\"", currency: "KWD"))
        XCTAssertEqual(wide.subtotal, Decimal(string: "123456789012345.678"))
        XCTAssertEqual(wide.subtotalString, "123456789012345.678")
        // Encode then decode: the exact text and every money field survive.
        let again = try JSONDecoder().decode(LensConfiguration.self, from: try JSONEncoder().encode(configuration))
        XCTAssertEqual(again, configuration)
        XCTAssertEqual(again.subtotalString, "22.345")
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(configuration)) as? [String: Any])
        XCTAssertEqual(encoded["subtotal"] as? String, "22.345")
        XCTAssertEqual(encoded["subtotal_minor"] as? Int, 22_345)
        XCTAssertEqual(encoded["currency_decimals"] as? Int, 3)
        XCTAssertEqual(encoded["price_basis"] as? String, "quote")
    }

    func testEURSubtotalKeepsTwoDecimalsAndMinorUnitsFollowTheCurrency() throws {
        let configuration = try decodeConfiguration(fixture: "configurations-201-eur-captured.json")
        XCTAssertEqual(configuration.subtotalString, "59.95")
        XCTAssertEqual(configuration.subtotal, Decimal(string: "59.95"))
        XCTAssertEqual(configuration.currencyMinorUnitDigits, 2)
        XCTAssertEqual(configuration.subtotalMinorUnits, 5_995)
        XCTAssertEqual(try decode(configurationJSON(subtotal: "\"1500\"", currency: "JPY")).subtotalMinorUnits, 1_500)
        XCTAssertNil(try decode(configurationJSON(subtotal: "\"12.3456\"", currency: "KWD")).subtotalMinorUnits, "more digits than the currency has is not a minor-unit amount")
        let unknown = try decode(configurationJSON(subtotal: "\"5.00\"", currency: nil))
        XCTAssertNil(unknown.currencyMinorUnitDigits)
        XCTAssertNil(unknown.subtotalMinorUnits)
    }

    func testSubtotalTextIsBoundedToFortyCharactersAndAnUnrepresentableNumberIsMalformed() async throws {
        let atBound = "123456789012345678901234567890.123456789"
        XCTAssertEqual(atBound.count, 40)
        let accepted = try decode(configurationJSON(subtotal: "\"\(atBound)\""))
        XCTAssertEqual(accepted.subtotalString, atBound)
        XCTAssertNil(accepted.subtotalMinorUnits, "nine decimals is not a KWD minor-unit amount, and asking must not trap")
        for bad in ["\"\(atBound)1\"", "\"\(String(repeating: "9", count: 41))\"", "\"-\(String(repeating: "9", count: 40))\""] {
            XCTAssertThrowsError(try decode(configurationJSON(subtotal: bad)), "\(bad.count - 2) characters")
        }
        // A trailing newline is not a plain decimal (a `$` anchor would let it through; Android's full match already refuses it).
        XCTAssertThrowsError(try decode(configurationJSON(subtotal: "\"12.00\\n\"")), "trailing newline")
        // A JSON number reaches the SDK as a Double: 1e308 is beyond Decimal, 1e127 is a 128 digit Decimal, and Foundation itself refuses 1e999999999.
        for huge in ["1e308", "-1e308", "1e127", "1e999999999", "1e-999999999"] {
            XCTAssertThrowsError(try decode(configurationJSON(subtotal: huge)), "subtotal \(huge)")
            let (journey, _) = try await summaryJourney(configurationBody: configurationJSON(subtotal: huge))
            do { _ = try await journey.finish(); XCTFail("Expected a malformed response for subtotal \(huge)") }
            catch let error as LensJourneyError { XCTAssertEqual(error.kind, .malformedResponse, "subtotal \(huge)") }
        }
        XCTAssertEqual(try decode(configurationJSON(subtotal: "12.5")).subtotal, Decimal(string: "12.5"))
    }

    func testServerCurrencyDecimalsWinWhenTheyDisagreeWithTheIsoTable() throws {
        // The table says KWD has 3; the server says 2. The server is authoritative.
        let configuration = try decode(configurationJSON(subtotal: "\"12.30\"", currency: "KWD", extra: "\"currency_decimals\":2"))
        XCTAssertEqual(configuration.currencyDecimals, 2)
        XCTAssertEqual(configuration.currencyMinorUnitDigits, 2)
        XCTAssertEqual(configuration.subtotalMinorUnits, 1_230)
        // ...and the other way: JPY is 0 in the table, the server says 2.
        let jpy = try decode(configurationJSON(subtotal: "\"15.50\"", currency: "JPY", extra: "\"currency_decimals\":2"))
        XCTAssertEqual(jpy.currencyMinorUnitDigits, 2)
        XCTAssertEqual(jpy.subtotalMinorUnits, 1_550)
        // Decimals with no currency still count.
        XCTAssertEqual(try decode(configurationJSON(subtotal: "\"1.5\"", currency: nil, extra: "\"currency_decimals\":1")).currencyMinorUnitDigits, 1)
    }

    func testServerSubtotalMinorIsPreferredOverAValueDerivedFromTheString() throws {
        let configuration = try decode(configurationJSON(subtotal: "\"1.234\"", currency: "KWD", extra: "\"subtotal_minor\":999,\"currency_decimals\":3"))
        XCTAssertEqual(configuration.subtotalMinor, 999)
        XCTAssertEqual(configuration.subtotalMinorUnits, 999)
    }

    func testMissingCurrencyDecimalsFallsBackToTheTableAndANonIntegerOneIsRejected() throws {
        XCTAssertNil(try decode(configurationJSON(subtotal: "\"1.000\"", currency: "KWD")).currencyDecimals)
        XCTAssertEqual(try decode(configurationJSON(subtotal: "\"1.000\"", currency: "KWD")).currencyMinorUnitDigits, 3)
        XCTAssertNil(try decode(configurationJSON(subtotal: "\"1.000\"", currency: "KWD", extra: "\"currency_decimals\":null")).currencyDecimals)
        // A whole-valued JSON number is an integer (3.0 == 3), a fractional or non-number one is not. Android agrees.
        for whole in ["3", "3.0", "3.00", "3e0", "30e-1"] {
            XCTAssertEqual(try decode(configurationJSON(subtotal: "\"1.000\"", currency: "KWD", extra: "\"currency_decimals\":\(whole)")).currencyDecimals, 3, "currency_decimals \(whole)")
        }
        for whole in ["22345", "22345.0", "2.2345e4"] {
            XCTAssertEqual(try decode(configurationJSON(subtotal: "\"22.345\"", currency: "KWD", extra: "\"subtotal_minor\":\(whole)")).subtotalMinor, 22_345, "subtotal_minor \(whole)")
        }
        for bad in ["3.5", "2.5", "0.5", "\"3\"", "true", "-1", "7", "{}", "[3]"] {
            XCTAssertThrowsError(try decode(configurationJSON(subtotal: "\"1.000\"", currency: "KWD", extra: "\"currency_decimals\":\(bad)")), "currency_decimals \(bad)")
        }
        for bad in ["22345.5", "22345.0001", "\"22345\"", "true", "[1]"] {
            XCTAssertThrowsError(try decode(configurationJSON(subtotal: "\"1.000\"", currency: "KWD", extra: "\"subtotal_minor\":\(bad)")), "subtotal_minor \(bad)")
        }
    }

    func testNonIntegerCurrencyDecimalsFailsFinishWithTheTypedError() async throws {
        let (journey, _) = try await summaryJourney(configurationBody: configurationJSON(subtotal: "\"1.000\"", currency: "KWD", extra: "\"currency_decimals\":3.5"))
        do { _ = try await journey.finish(); XCTFail("Expected a malformed response") }
        catch let error as LensJourneyError { XCTAssertEqual(error.kind, .malformedResponse) }
    }

    func testDecodesTheCapturedKWDAndEURResponsesFieldForField() async throws {
        let kwd = try capturedPair("configurations-201-kwd-captured.json")
        let eur = try capturedPair("configurations-201-eur-captured.json")
        let note = "Indicative quote. The merchant cart re-prices every line and is the charging authority; this configuration is never charged."
        for (label, subtotal, minor, decimals, currency, body, both) in [
            ("KWD", "22.345", Int64(22_345), 3, "KWD", kwd.post, kwd.get),
            ("EUR", "59.95", Int64(5_995), 2, "EUR", eur.post, eur.get),
        ] {
            // The id is whatever the captured fixture holds (it changes on every re-capture), read from the raw JSON, not hard-coded.
            let postID = try XCTUnwrap(try jsonObject(body)["id"] as? String, "\(label) fixture POST id")
            let getID = try XCTUnwrap(try jsonObject(both)["id"] as? String, "\(label) fixture GET id")
            XCTAssertFalse(postID.isEmpty, "\(label) fixture POST id is empty")
            XCTAssertEqual(getID, postID, "\(label): the follow-up GET returns the configuration the POST created")
            for (shape, data) in [("POST 201", body), ("follow-up GET", both)] {
                let c = try decode(data)
                XCTAssertEqual(c.id, postID, "\(label) \(shape)")
                XCTAssertEqual(c.subtotal, Decimal(string: subtotal), "\(label) \(shape)")
                XCTAssertEqual(c.subtotalString, subtotal, "\(label) \(shape)")
                XCTAssertEqual(c.subtotalMinor, minor, "\(label) \(shape)")
                XCTAssertEqual(c.currencyDecimals, decimals, "\(label) \(shape)")
                XCTAssertEqual(c.currency, currency, "\(label) \(shape)")
                XCTAssertEqual(c.priceBasis, "quote", "\(label) \(shape)")
                XCTAssertEqual(c.priceBasisNote, note, "\(label) \(shape)")
                XCTAssertTrue(c.isQuote)
                XCTAssertNil(c.subtotalPaise, "\(label) \(shape): catalogue markets send no subtotal_paise")
                XCTAssertEqual(c.currencyMinorUnitDigits, decimals); XCTAssertEqual(c.subtotalMinorUnits, minor)
                XCTAssertEqual(c.breakdown.count, 3, "\(label) \(shape)")
            }
            XCTAssertEqual(try decode(body).inheritedFromPartner, false); XCTAssertEqual(try decode(body).prescriptionOnFile, false)
            XCTAssertNil(try decode(body).status); XCTAssertEqual(try decode(both).status, "draft")
        }
        // The POST body also survives a whole finish() call.
        let (journey, _) = try await summaryJourney(configurationBody: kwd.post)
        let finished = try await journey.finish()
        XCTAssertEqual(finished.subtotalMinorUnits, 22_345); XCTAssertEqual(finished.priceBasis, "quote")
    }

    func testAbsentOrNullSubtotalIsNil() throws {
        XCTAssertNil(try decode(configurationJSON(subtotal: "null")).subtotal)
        XCTAssertNil(try decode(configurationJSON(subtotal: nil)).subtotal)
        XCTAssertNil(try decode(configurationJSON(subtotal: "null")).subtotalString)
    }

    func testMalformedSubtotalFailsFinishWithTheTypedMalformedResponseError() async throws {
        for bad in ["\"twelve\"", "\"\"", "\"1,5\"", "\"NaN\"", "\"Infinity\"", "\"12.\"", "\" 12\"", "\"1e3\"", "\"0x10\"", "true", "{}", "[1]"] {
            let (journey, _) = try await summaryJourney(configurationBody: configurationJSON(subtotal: bad))
            do { _ = try await journey.finish(); XCTFail("Expected a malformed response for subtotal \(bad)") }
            catch let error as LensJourneyError {
                XCTAssertEqual(error.kind, .malformedResponse, "subtotal \(bad)")
                XCTAssertEqual(error.code, "MALFORMED_RESPONSE")
            }
        }
    }

    func testAGoodStringSubtotalSurvivesTheWholeFinishCall() async throws {
        let (journey, _) = try await summaryJourney(configurationBody: configurationJSON(subtotal: "\"12.345\"", currency: "KWD"))
        let configuration = try await journey.finish()
        XCTAssertEqual(configuration.subtotalString, "12.345")
        XCTAssertEqual(configuration.subtotal, Decimal(string: "12.345"))
    }

    func testBrandIsSentOnEvaluateAndConfigurationsWhenSet() async throws {
        let (journey, transport) = try await summaryJourney(configurationBody: configurationJSON(subtotal: "\"1.00\""), brand: "BRANDB")
        _ = try await journey.finish()
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 4)
        for request in requests { XCTAssertEqual(try jsonObject(request.body)["brand"] as? String, "BRANDB", request.path) }
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("/evaluate") }.count, 3)
        XCTAssertTrue(requests.last?.path.hasSuffix("/configurations") == true)
    }

    func testBrandIsAbsentWhenNotSet() async throws {
        let (journey, transport) = try await summaryJourney(configurationBody: configurationJSON(subtotal: "\"1.00\""))
        _ = try await journey.finish()
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 4)
        for request in requests { XCTAssertFalse(try jsonObject(request.body).keys.contains("brand"), request.path) }
    }

    func testBrandMatchesTheServersRuleAndIsTrimmed() throws {
        for good in ["ACME", "BRANDB", "acme", "Z", "A1", String(repeating: "a", count: 32)] {
            XCTAssertEqual(try JourneyConfig(clientId: "client_12345", brand: good).brand, good, good)
        }
        XCTAssertEqual(try JourneyConfig(clientId: "client_12345", brand: "  ACME\n").wireBrand, "ACME", "trimmed before it is checked and sent")
        for bad in ["", "   ", "1ACME", "AC ME", "AC-ME", "ACME_", "AC.ME", "ACME!", "ACMÉ", "ACME😀", "٣ACME", String(repeating: "a", count: 33)] {
            XCTAssertThrowsError(try JourneyConfig(clientId: "client_12345", brand: bad), "brand \(bad.debugDescription)") { XCTAssertEqual(($0 as? LensJourneyError)?.kind, .invalidRequest) }
        }
        XCTAssertNil(try JourneyConfig(clientId: "client_12345").brand)
    }

    func testTheTrimmedBrandIsWhatIsSent() async throws {
        let (journey, transport) = try await summaryJourney(configurationBody: configurationJSON(subtotal: "\"1.00\""), brand: " brandb ")
        _ = try await journey.finish()
        for request in await transport.requests { XCTAssertEqual(try jsonObject(request.body)["brand"] as? String, "brandb") }
    }

    func testVersionIsZeroPointTwoPointZeroAndMatchesVersionFileAndChangelog() throws {
        XCTAssertEqual(LensJourney.version, "0.2.0")
        let root = sdkPackageRoot()
        let versionFile = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(versionFile, LensJourney.version, "VERSION must equal LensJourney.version")
        let changelog = try String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        let newest = changelog.split(separator: "\n").first { $0.hasPrefix("## ") }.map { $0.dropFirst(3).split(separator: " ").first.map(String.init) ?? "" }
        XCTAssertEqual(newest, LensJourney.version, "the newest CHANGELOG.md heading must carry the current version")
    }
}

private actor ScriptTransport: Transport {
    private(set) var requests: [TransportRequest] = []
    private var responses: [TransportResponse]
    init(_ responses: [TransportResponse]) { self.responses = responses }
    func send(_ request: TransportRequest) async throws -> TransportResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return responses.removeFirst()
    }
}

private func fixturesDirectory() -> URL {
    sdkFixturesDirectory()
}
private func fixtureResponse(_ name: String) throws -> TransportResponse {
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixturesDirectory().appendingPathComponent(name))) as? [String: Any])
    let response = try XCTUnwrap(root["response"] as? [String: Any])
    return TransportResponse(status: try XCTUnwrap(response["status"] as? Int), body: try JSONSerialization.data(withJSONObject: try XCTUnwrap(response["body"])))
}
private func decodeConfiguration(fixture name: String) throws -> LensConfiguration { try decode(try fixtureResponse(name).body) }
private func decode(_ data: Data) throws -> LensConfiguration { try JSONDecoder().decode(LensConfiguration.self, from: data) }
/// Raw JSON text so a number stays a JSON number and a string stays a string. `subtotal` is spliced in verbatim; nil omits the key.
private func configurationJSON(subtotal: String?, currency: String? = "KWD", extra: String? = nil) -> Data {
    var fields = ["\"success\":true", "\"id\":\"11111111-2222-4333-8444-555555555555\"", "\"lens_summary\":null", "\"breakdown\":[]", "\"inherited_from_partner\":false", "\"prescription_on_file\":true"]
    if let subtotal { fields.append("\"subtotal\":\(subtotal)") }
    if let currency { fields.append("\"currency\":\"\(currency)\"") }
    if let extra { fields.append(extra) }
    return Data("{\(fields.joined(separator: ","))}".utf8)
}
/// The captured fixture's POST 201 body and its follow_up_get body, re-serialised.
private func capturedPair(_ name: String) throws -> (post: Data, get: Data) {
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixturesDirectory().appendingPathComponent(name))) as? [String: Any])
    let post = try XCTUnwrap((root["response"] as? [String: Any])?["body"])
    let get = try XCTUnwrap(((root["follow_up_get"] as? [String: Any])?["response"] as? [String: Any])?["body"])
    return (try JSONSerialization.data(withJSONObject: post), try JSONSerialization.data(withJSONObject: get))
}
private func jsonObject(_ data: Data?) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(data)) as? [String: Any]) }
/// start + two selects reach the summary terminal; the next transport response is the /configurations body.
private func summaryJourney(configurationBody: Data, brand: String? = nil) async throws -> (LensJourney, ScriptTransport) {
    let transport = ScriptTransport([
        try fixtureResponse("evaluate-first-choice.json"), try fixtureResponse("evaluate-second-choice.json"), try fixtureResponse("evaluate-summary.json"),
        TransportResponse(status: 201, body: configurationBody),
    ])
    let journey = LensJourney(config: try JourneyConfig(sessionId: "fixture-session-0001", clientId: "client_12345", brand: brand), transport: transport)
    _ = try await journey.start(category: "single-vision", frame: FrameRef(sku: "FIXTURE-SKU"), vision: .distance)
    _ = try await journey.select(optionId: "anti-reflective")
    _ = try await journey.select(optionId: "opt-anti-reflective-150-stock")
    return (journey, transport)
}
