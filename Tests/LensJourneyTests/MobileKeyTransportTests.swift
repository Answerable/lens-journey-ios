import XCTest
@testable import LensJourney

final class MobileKeyTransportTests: XCTestCase {
    private let base = URL(string: "https://shop.example.com")!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: key refusal

    func testASecretKeyIsRefusedBeforeAnythingElseHappens() {
        for key in ["cs_live_abcdefghijklmnop", "cs_", "CS_Live_abc", "cs_test_x"] {
            XCTAssertThrowsError(try config(key: key), key) { error in
                let e = error as? LensJourneyError
                XCTAssertEqual(e?.kind, .invalidConfiguration, key)
                XCTAssertEqual(e?.code, "SECRET_KEY_IN_APP", key)
                XCTAssertTrue(e?.message.contains("must never ship in an app") == true, key)
            }
        }
    }

    func testAnythingThatIsNotAMobilePublishableKeyIsRefused() {
        for key in ["", "cspk_", "pk_live_abcdef", "cspk-live-abc", "xcspk_abc", " cspk_abc", "cspk_ab cd", "cspk_abç"] {
            XCTAssertThrowsError(try config(key: key), key) { error in
                XCTAssertEqual((error as? LensJourneyError)?.kind, .invalidConfiguration, key)
                XCTAssertEqual((error as? LensJourneyError)?.code, "INVALID_MOBILE_KEY", key)
            }
        }
        XCTAssertNoThrow(try config(key: "cspk_live_abc123"))
    }

    func testTheKeyIsNeverPrinted() throws {
        let c = try config(key: "cspk_live_supersecretvalue")
        XCTAssertFalse("\(c)".contains("supersecretvalue"))
        XCTAssertFalse(String(describing: c).contains("supersecretvalue"))
    }

    func testTheLensJourneyFactoryRefusesASecretKeyToo() async {
        do {
            _ = try LensJourney.mobile(config: try JourneyConfig(), mobileKey: try config(key: "cs_live_abcdefghijklmnop"))
            XCTFail("expected a refusal")
        } catch { XCTAssertEqual((error as? LensJourneyError)?.kind, .invalidConfiguration) }
    }

    func testANonHTTPSBaseURLIsRefusedUnlessAllowedForDebug() throws {
        let c = try MobileKeyConfig(mobileKey: "cspk_live_abc123", baseURL: URL(string: "http://localhost:3000")!, attestationProvider: EchoChallengeProvider())
        XCTAssertThrowsError(try MobileKeyTransport(config: c)) { XCTAssertEqual(($0 as? LensJourneyError)?.code, "INSECURE_BASE_URL") }
        let ok = try MobileKeyConfig(mobileKey: "cspk_live_abc123", baseURL: URL(string: "http://localhost:3000")!, attestationProvider: EchoChallengeProvider(), allowInsecureHTTP: true)
        XCTAssertNoThrow(try MobileKeyTransport(config: ok))
    }

    // MARK: nonce -> attest -> token -> journey header

    func testFirstJourneyCallRunsNonceAttestTokenAndSendsTheInstallTokenHeader() async throws {
        let stub = StubServer(now: start)
        let provider = RecordingProvider(payload: .debug(challenge: "echo"))
        let store = InMemoryInstallIdStore()
        let transport = try makeTransport(stub: stub, provider: provider, store: store)

        let response = try await transport.send(TransportRequest(method: "POST", path: "/api/v1/lens-journey/evaluate", headers: ["X-Client-Id": "client_123"], body: Data("{}".utf8), contentType: "application/json"))
        XCTAssertEqual(response.status, 200)

        let calls = await stub.calls
        XCTAssertEqual(calls.map(\.path), ["/api/v1/lens-journey/install-nonce", "/api/v1/lens-journey/install-token", "/api/v1/lens-journey/evaluate"])

        let installId = try XCTUnwrap(store.load())
        XCTAssertNotNil(installId.range(of: "^[A-Za-z0-9_-]{16,64}$", options: .regularExpression), "the install id must match the server's rule")

        let nonce = calls[0]
        XCTAssertEqual(nonce.method, "POST")
        XCTAssertEqual(nonce.headers["X-API-Key"], "cspk_live_abc123")
        XCTAssertEqual(nonce.contentType, "application/json")
        let nonceBody = try json(nonce.body)
        XCTAssertEqual(nonceBody["install_id"] as? String, installId)
        XCTAssertEqual(nonceBody["platform"] as? String, "ios")

        let attested = await provider.calls
        XCTAssertEqual(attested.map(\.challenge), ["challenge-1"], "the provider attests over the server's challenge")
        XCTAssertEqual(attested.map(\.installId), [installId])

        let token = calls[1]
        XCTAssertEqual(token.headers["X-API-Key"], "cspk_live_abc123")
        let tokenBody = try json(token.body)
        XCTAssertEqual(tokenBody["install_id"] as? String, installId)
        XCTAssertEqual(tokenBody["platform"] as? String, "ios")
        XCTAssertEqual(tokenBody["nonce"] as? String, "nonce-1")
        XCTAssertEqual((tokenBody["debug"] as? [String: Any])?["challenge"] as? String, "echo")
        XCTAssertNil(tokenBody["ios"]); XCTAssertNil(tokenBody["android"])

        let journey = calls[2]
        XCTAssertEqual(journey.headers["X-CS-Install-Token"], "token-1")
        XCTAssertEqual(journey.headers["X-Client-Id"], "client_123", "the caller's own headers survive")
        XCTAssertNil(journey.headers["X-API-Key"], "the mobile key is only sent on the mint calls")
        XCTAssertEqual(journey.body, Data("{}".utf8))
        let accepted = await provider.accepted
        XCTAssertEqual(accepted, [installId])
    }

    func testAppAttestPayloadsMapToTheIosWireFields() async throws {
        let stub = StubServer(now: start)
        let provider = RecordingProvider(payload: .appAttest(keyId: "key-1", attestationObject: Data([1, 2, 3]), assertion: nil))
        let transport = try makeTransport(stub: stub, provider: provider)
        _ = try await transport.send(journeyRequest())
        let bodyCalls = await stub.calls
        let body = try json(bodyCalls[1].body)
        let ios = try XCTUnwrap(body["ios"] as? [String: Any])
        XCTAssertEqual(ios["key_id"] as? String, "key-1")
        XCTAssertEqual(ios["attestation_object"] as? String, Data([1, 2, 3]).base64EncodedString())
        XCTAssertNil(ios["assertion"])

        let refresh = StubServer(now: start)
        let assertion = RecordingProvider(payload: .appAttest(keyId: "key-1", attestationObject: nil, assertion: Data([9, 9])))
        _ = try await makeTransport(stub: refresh, provider: assertion).send(journeyRequest())
        let ios2Calls = await refresh.calls
        let ios2 = try XCTUnwrap(try json(ios2Calls[1].body)["ios"] as? [String: Any])
        XCTAssertEqual(ios2["assertion"] as? String, Data([9, 9]).base64EncodedString())
        XCTAssertNil(ios2["attestation_object"])
    }

    func testAPlayIntegrityPayloadMapsToTheAndroidWireField() async throws {
        let stub = StubServer(now: start)
        let transport = try makeTransport(stub: stub, provider: RecordingProvider(payload: .playIntegrity(token: "pi-token")))
        _ = try await transport.send(journeyRequest())
        let bodyCalls = await stub.calls
        let body = try json(bodyCalls[1].body)
        XCTAssertEqual((body["android"] as? [String: Any])?["integrity_token"] as? String, "pi-token")
    }

    func testTheTokenAndInstallIdAreReusedAcrossCalls() async throws {
        let stub = StubServer(now: start)
        let store = InMemoryInstallIdStore()
        let transport = try makeTransport(stub: stub, provider: RecordingProvider(payload: .debug(challenge: "c")), store: store)
        for _ in 0..<3 { _ = try await transport.send(journeyRequest()) }
        let calls = await stub.calls
        XCTAssertEqual(calls.filter { $0.path.hasSuffix("install-nonce") }.count, 1)
        XCTAssertEqual(calls.filter { $0.path.hasSuffix("install-token") }.count, 1)
        XCTAssertEqual(calls.filter { $0.path.hasSuffix("evaluate") }.map { $0.headers["X-CS-Install-Token"] }, ["token-1", "token-1", "token-1"])
    }

    func testAStoredInstallIdIsReusedAndAnInvalidOneIsReplaced() async throws {
        let stub = StubServer(now: start)
        let store = InMemoryInstallIdStore(installId: "stored-install-id-0001")
        _ = try await makeTransport(stub: stub, provider: RecordingProvider(payload: .debug(challenge: "c")), store: store).send(journeyRequest())
        let c1 = await stub.calls
        XCTAssertEqual(try json(c1[0].body)["install_id"] as? String, "stored-install-id-0001")

        let junk = InMemoryInstallIdStore(installId: "short")
        let stub2 = StubServer(now: start)
        _ = try await makeTransport(stub: stub2, provider: RecordingProvider(payload: .debug(challenge: "c")), store: junk).send(journeyRequest())
        let replaced = try XCTUnwrap(junk.load())
        XCTAssertNotEqual(replaced, "short")
        let c2 = await stub2.calls
        XCTAssertEqual(try json(c2[0].body)["install_id"] as? String, replaced)
    }

    func testConcurrentFirstCallsMintOnce() async throws {
        let stub = StubServer(now: start, mintDelayNanoseconds: 20_000_000)
        let transport = try makeTransport(stub: stub, provider: RecordingProvider(payload: .debug(challenge: "c")))
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<5 { group.addTask { try await transport.send(self.journeyRequest()).status } }
            for try await status in group { XCTAssertEqual(status, 200) }
        }
        let got3 = await stub.calls.filter { $0.path.hasSuffix("install-nonce") }.count
        XCTAssertEqual(got3, 1)
    }

    // MARK: refresh

    func testTheTokenIsRefreshedFiveMinutesBeforeItExpires() async throws {
        let stub = StubServer(now: start, lifetime: 3600)
        let clock = TestClock(start)
        let provider = RecordingProvider(payload: .debug(challenge: "c"))
        let transport = try makeTransport(stub: stub, provider: provider, clock: clock)
        _ = try await transport.send(journeyRequest())

        clock.set(start.addingTimeInterval(3600 - 301))
        _ = try await transport.send(journeyRequest())
        let got4 = await stub.mintCount
        XCTAssertEqual(got4, 1, "301 s before expiry the token is still used")

        clock.set(start.addingTimeInterval(3600 - 299))
        _ = try await transport.send(journeyRequest())
        let got5 = await stub.mintCount
        XCTAssertEqual(got5, 2, "within 5 minutes of expiry the SDK mints a new token")
        let lastCalls = await stub.calls
        let last = try XCTUnwrap(lastCalls.last)
        XCTAssertEqual(last.headers["X-CS-Install-Token"], "token-2")
        let accepted = await provider.accepted.count
        XCTAssertEqual(accepted, 2)
    }

    func testAShortLivedTokenIsNotReMintedOnEveryCall() async throws {
        let stub = StubServer(now: start, lifetime: 120)
        let clock = TestClock(start)
        let transport = try makeTransport(stub: stub, provider: RecordingProvider(payload: .debug(challenge: "c")), clock: clock)
        _ = try await transport.send(journeyRequest())
        clock.set(start.addingTimeInterval(30))
        _ = try await transport.send(journeyRequest())
        let got6 = await stub.mintCount
        XCTAssertEqual(got6, 1)
    }

    func testAFailedRefreshFallsBackToTheTokenThatIsStillValid() async throws {
        let stub = StubServer(now: start, lifetime: 3600)
        let clock = TestClock(start)
        let transport = try makeTransport(stub: stub, provider: RecordingProvider(payload: .debug(challenge: "c")), clock: clock)
        _ = try await transport.send(journeyRequest())
        await stub.failNextNonce(status: 503)
        clock.set(start.addingTimeInterval(3600 - 200))
        let response = try await transport.send(journeyRequest())
        XCTAssertEqual(response.status, 200)
        let c7 = await stub.calls
        XCTAssertEqual(try XCTUnwrap(c7.last).headers["X-CS-Install-Token"], "token-1")
    }

    func testAnExpiredTokenWhoseRefreshFailsSurfacesTheError() async throws {
        let stub = StubServer(now: start, lifetime: 3600)
        let clock = TestClock(start)
        let transport = try makeTransport(stub: stub, provider: RecordingProvider(payload: .debug(challenge: "c")), clock: clock)
        _ = try await transport.send(journeyRequest())
        await stub.failNextNonce(status: 503)
        clock.set(start.addingTimeInterval(3601))
        do { _ = try await transport.send(journeyRequest()); XCTFail("expected an error") }
        catch { XCTAssertEqual((error as? LensJourneyError)?.kind, .unavailable) }
    }

    // MARK: re-mint on 401 INSTALL_TOKEN_INVALID

    func testA401InstallTokenInvalidMintsOnceAndRetriesTheCall() async throws {
        let stub = StubServer(now: start)
        await stub.rejectJourneyToken("token-1", code: "INSTALL_TOKEN_INVALID")
        let transport = try makeTransport(stub: stub, provider: RecordingProvider(payload: .debug(challenge: "c")))
        let response = try await transport.send(journeyRequest(body: "{\"a\":1}"))
        XCTAssertEqual(response.status, 200)
        let calls = await stub.calls
        XCTAssertEqual(calls.map(\.path), ["/api/v1/lens-journey/install-nonce", "/api/v1/lens-journey/install-token", "/api/v1/lens-journey/evaluate",
                                           "/api/v1/lens-journey/install-nonce", "/api/v1/lens-journey/install-token", "/api/v1/lens-journey/evaluate"])
        guard calls.count == 6 else { return XCTFail("expected six calls, got \(calls.count)") }   // a regression must fail the test, not trap on the index below
        XCTAssertEqual(calls[2].headers["X-CS-Install-Token"], "token-1")
        XCTAssertEqual(calls[5].headers["X-CS-Install-Token"], "token-2")
        XCTAssertEqual(calls[5].body, calls[2].body, "the retry resends the same body")
    }

    func testTheReMintHappensOnlyOncePerCall() async throws {
        let stub = StubServer(now: start)
        await stub.rejectAllJourneyTokens(code: "INSTALL_TOKEN_INVALID")
        let transport = try makeTransport(stub: stub, provider: RecordingProvider(payload: .debug(challenge: "c")))
        let response = try await transport.send(journeyRequest())
        XCTAssertEqual(response.status, 401, "the second 401 is returned, not retried again")
        let got8 = await stub.calls.filter { $0.path.hasSuffix("evaluate") }.count
        XCTAssertEqual(got8, 2)
        let got9 = await stub.mintCount
        XCTAssertEqual(got9, 2)
    }

    func testOtherUnauthorizedAnswersAreNotReMinted() async throws {
        let stub = StubServer(now: start)
        await stub.rejectAllJourneyTokens(code: "SOMETHING_ELSE")
        let transport = try makeTransport(stub: stub, provider: RecordingProvider(payload: .debug(challenge: "c")))
        let got10 = try await transport.send(journeyRequest()).status
        XCTAssertEqual(got10, 401)
        let got11 = await stub.mintCount
        XCTAssertEqual(got11, 1)
        let got12 = await stub.calls.filter { $0.path.hasSuffix("evaluate") }.count
        XCTAssertEqual(got12, 1)
    }

    func testTwoCallsRejectedTogetherShareOneReMint() async throws {
        let stub = StubServer(now: start, mintDelayNanoseconds: 20_000_000)
        let transport = try makeTransport(stub: stub, provider: RecordingProvider(payload: .debug(challenge: "c")))
        _ = try await transport.send(journeyRequest())           // token-1
        await stub.rejectJourneyToken("token-1", code: "INSTALL_TOKEN_INVALID")
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<2 { group.addTask { try await transport.send(self.journeyRequest()).status } }
            for try await status in group { XCTAssertEqual(status, 200) }
        }
        let got13 = await stub.mintCount
        XCTAssertEqual(got13, 2, "one initial mint plus one shared re-mint")
    }

    func testACallRejectedAfterAnotherCallAlreadyReplacedTheTokenReusesTheNewOne() async throws {
        let stub = StubServer(now: start)
        let transport = try makeTransport(stub: stub, provider: RecordingProvider(payload: .debug(challenge: "c")))
        _ = try await transport.send(journeyRequest())           // token-1
        await stub.rejectJourneyToken("token-1", code: "INSTALL_TOKEN_INVALID")
        var slow = journeyRequest(); slow = TransportRequest(method: slow.method, path: slow.path, headers: ["X-Slow": "1"], body: slow.body, contentType: slow.contentType)
        async let slowStatus = transport.send(slow)                // sent with token-1, answered 401 only after the fast call is done
        try await Task.sleep(nanoseconds: 30_000_000)
        let fast = try await transport.send(journeyRequest())      // 401, mints token-2, 200
        let late = try await slowStatus
        XCTAssertEqual(fast.status, 200); XCTAssertEqual(late.status, 200)
        let mints = await stub.mintCount
        XCTAssertEqual(mints, 2, "the late 401 must reuse token-2, not mint token-3")
    }

    // MARK: typed attestation errors

    func testAProviderFailureIsATypedAttestationError() async throws {
        let stub = StubServer(now: start)
        let transport = try makeTransport(stub: stub, provider: ThrowingProvider(error: URLError(.cannotFindHost)))
        do { _ = try await transport.send(journeyRequest()); XCTFail("expected an error") }
        catch {
            let e = error as? LensJourneyError
            XCTAssertEqual(e?.kind, .attestationFailed); XCTAssertEqual(e?.code, "ATTESTATION_FAILED")
        }
        let got14 = await stub.calls.filter { $0.path.hasSuffix("evaluate") }.count
        XCTAssertEqual(got14, 0, "no journey call is sent without a token")
    }

    func testAProvidersOwnTypedErrorPassesThrough() async throws {
        let own = LensJourneyError(kind: .attestationFailed, code: "ATTESTATION_UNAVAILABLE", message: "This device cannot attest")
        let transport = try makeTransport(stub: StubServer(now: start), provider: ThrowingProvider(error: own))
        do { _ = try await transport.send(journeyRequest()); XCTFail("expected an error") } catch { XCTAssertEqual(error as? LensJourneyError, own) }
    }

    func testAServerAttestationRefusalIsTypedAndTellsTheProvider() async throws {
        let stub = StubServer(now: start)
        await stub.failNextToken(status: 401, code: "ATTESTATION_FAILED")
        let provider = RecordingProvider(payload: .debug(challenge: "c"))
        let transport = try makeTransport(stub: stub, provider: provider)
        do { _ = try await transport.send(journeyRequest()); XCTFail("expected an error") }
        catch {
            let e = error as? LensJourneyError
            XCTAssertEqual(e?.kind, .attestationFailed); XCTAssertEqual(e?.code, "ATTESTATION_FAILED"); XCTAssertEqual(e?.requestId, "req-1")
        }
        let rejected = await provider.rejected.count, accepted = await provider.accepted.count
        XCTAssertEqual(rejected, 1); XCTAssertEqual(accepted, 0)
        // The next call tries again from scratch.
        let got15 = try await transport.send(journeyRequest()).status
        XCTAssertEqual(got15, 200)
    }

    func testADisabledMobileChannelIsTyped() async throws {
        let stub = StubServer(now: start)
        await stub.failNextNonce(status: 403, code: "MOBILE_CHANNEL_DISABLED")
        let transport = try makeTransport(stub: stub, provider: RecordingProvider(payload: .debug(challenge: "c")))
        do { _ = try await transport.send(journeyRequest()); XCTFail("expected an error") }
        catch { XCTAssertEqual((error as? LensJourneyError)?.kind, .mobileChannelDisabled) }
    }

    func testAMintResponseTheSDKCannotReadIsMalformed() async throws {
        let stub = StubServer(now: start)
        await stub.garbleNextToken()
        let transport = try makeTransport(stub: stub, provider: RecordingProvider(payload: .debug(challenge: "c")))
        do { _ = try await transport.send(journeyRequest()); XCTFail("expected an error") }
        catch { XCTAssertEqual((error as? LensJourneyError)?.kind, .malformedResponse) }
    }

    // MARK: mint failures the server really sends

    func testMintErrorsMapToTypedKindsAndNeverLoopOrSendAJourneyCall() async throws {
        let cases: [(route: String, status: Int, code: String, kind: LensJourneyError.Kind)] = [
            ("nonce", 429, "RATE_LIMITED", .rateLimited),
            ("token", 429, "INSTALL_CAP_EXCEEDED", .rateLimited),
            ("token", 403, "INSTALL_REVOKED", .insufficientScope),
            ("nonce", 403, "MOBILE_BINDING_NOT_ACTIVE", .insufficientScope),
            ("nonce", 401, "INVALID_API_KEY", .unauthorized),
            ("token", 503, "MOBILE_CHANNEL_UNAVAILABLE", .unavailable),
            ("token", 400, "INVALID_REQUEST", .invalidRequest),
        ]
        for c in cases {
            let stub = StubServer(now: start)
            if c.route == "nonce" { await stub.failNextNonce(status: c.status, code: c.code) } else { await stub.failNextToken(status: c.status, code: c.code) }
            let provider = RecordingProvider(payload: .debug(challenge: "c"))
            let transport = try makeTransport(stub: stub, provider: provider)
            do { _ = try await transport.send(journeyRequest()); XCTFail("\(c.code): expected an error") }
            catch {
                let e = error as? LensJourneyError
                XCTAssertEqual(e?.kind, c.kind, c.code); XCTAssertEqual(e?.code, c.code, c.code)
            }
            let journeyCalls = await stub.calls.filter { $0.path.hasSuffix("evaluate") }.count
            XCTAssertEqual(journeyCalls, 0, "\(c.code): no journey call without a token")
            let mints = await stub.calls.filter { $0.path.hasSuffix("install-token") || $0.path.hasSuffix("install-nonce") }.count
            XCTAssertLessThanOrEqual(mints, 2, "\(c.code): the mint is not retried")
        }
    }

    func testAnExpiresAtWithMillisecondsIsRead() async throws {
        let stub = StubServer(now: start, lifetime: 3600)
        let clock = TestClock(start)
        let transport = try makeTransport(stub: stub, provider: RecordingProvider(payload: .debug(challenge: "c")), clock: clock)
        _ = try await transport.send(journeyRequest())
        clock.set(start.addingTimeInterval(3600 - 299))
        _ = try await transport.send(journeyRequest())
        let mints = await stub.mintCount
        XCTAssertEqual(mints, 2, "a `.000Z` expiry decodes, so the refresh window is honoured")
    }

    func testATokenReplyWithAnUnreadableExpiryOrNoTokenIsMalformed() async throws {
        for reply: [String: Any] in [
            ["install_token": "t", "expires_at": "tomorrow"],
            ["install_token": "", "expires_at": "2099-01-01T00:00:00.000Z"],
            ["expires_at": "2099-01-01T00:00:00.000Z"],
        ] {
            let stub = StubServer(now: start)
            await stub.replyToNextToken(with: reply)
            let transport = try makeTransport(stub: stub, provider: RecordingProvider(payload: .debug(challenge: "c")))
            do { _ = try await transport.send(journeyRequest()); XCTFail("expected an error for \(reply)") }
            catch { XCTAssertEqual((error as? LensJourneyError)?.kind, .malformedResponse) }
        }
    }

    func testALegacyEnvelopeCodeIsRecognisedForTheRemint() async throws {
        let stub = StubServer(now: start)
        await stub.useLegacyEnvelope()
        await stub.rejectJourneyToken("token-1", code: "INSTALL_TOKEN_INVALID")
        let transport = try makeTransport(stub: stub, provider: RecordingProvider(payload: .debug(challenge: "c")))
        let status = try await transport.send(journeyRequest()).status
        XCTAssertEqual(status, 200)
        let mints = await stub.mintCount
        XCTAssertEqual(mints, 2)
    }

    func testTheMobileKeyIsNeverSentOnJourneyCallsAndTheTokenNeverOnMintCalls() async throws {
        let stub = StubServer(now: start)
        await stub.rejectJourneyToken("token-1", code: "INSTALL_TOKEN_INVALID")
        let transport = try makeTransport(stub: stub, provider: RecordingProvider(payload: .debug(challenge: "c")))
        _ = try await transport.send(journeyRequest())     // mint, 401, re-mint, 200
        let calls = await stub.calls
        XCTAssertEqual(calls.count, 6)
        for call in calls {
            if call.path.hasSuffix("install-nonce") || call.path.hasSuffix("install-token") {
                XCTAssertEqual(call.headers["X-API-Key"], "cspk_live_abc123"); XCTAssertNil(call.headers["X-CS-Install-Token"])
            } else {
                XCTAssertNil(call.headers["X-API-Key"], "no journey call carries the mobile key, including the retry"); XCTAssertNotNil(call.headers["X-CS-Install-Token"])
            }
        }
    }

    // MARK: a failed refresh is not retried on every call

    func testAFailedRefreshIsNotRetriedOnEveryCallForThirtySeconds() async throws {
        let stub = StubServer(now: start, lifetime: 3600)
        let clock = TestClock(start)
        let transport = try makeTransport(stub: stub, provider: RecordingProvider(payload: .debug(challenge: "c")), clock: clock)
        _ = try await transport.send(journeyRequest())
        clock.set(start.addingTimeInterval(3600 - 200))
        await stub.failNextNonce(status: 503)
        _ = try await transport.send(journeyRequest())                       // refresh fails, old token used
        let before = await stub.calls.filter { $0.path.hasSuffix("install-nonce") }.count
        for _ in 0..<5 { _ = try await transport.send(journeyRequest()) }
        let during = await stub.calls.filter { $0.path.hasSuffix("install-nonce") }.count
        XCTAssertEqual(during, before, "no new mint attempts inside the back-off")
        clock.set(start.addingTimeInterval(3600 - 200 + MobileKeyTransport.refreshRetryDelay + 1))
        _ = try await transport.send(journeyRequest())
        let after = await stub.mintCount
        XCTAssertEqual(after, 2, "after the back-off the refresh succeeds")
    }

    // MARK: App Attest recovery (the server accepts a new attestation only for an install without an accepted key)

    func testARefusedFirstAttestationStartsANewInstallAndMintsOnceMoreInTheSameCall() async throws {
        let stub = StubServer(now: start)
        await stub.failNextToken(status: 401, code: "ATTESTATION_FAILED")      // e.g. key_already_accepted for a restored install id
        let provider = RecordingProvider(payload: .appAttest(keyId: "key-1", attestationObject: Data([1]), assertion: nil))
        let store = InMemoryInstallIdStore(installId: "restored-install-id-1")
        let transport = try makeTransport(stub: stub, provider: provider, store: store)
        let status = try await transport.send(journeyRequest()).status
        XCTAssertEqual(status, 200)
        let nonces = try await stub.calls.filter { $0.path.hasSuffix("install-nonce") }.map { try json($0.body)["install_id"] as? String }
        XCTAssertEqual(nonces.count, 2); XCTAssertEqual(nonces[0], "restored-install-id-1"); XCTAssertNotEqual(nonces[1], "restored-install-id-1")
        XCTAssertEqual(store.load(), nonces[1], "the new install id is persisted")
        XCTAssertNotNil(nonces[1]?.range(of: "^[A-Za-z0-9_-]{16,64}$", options: .regularExpression), "the new id matches the server's rule")
        let tokenBodies = try await stub.calls.filter { $0.path.hasSuffix("install-token") }.map { try json($0.body) }
        XCTAssertEqual(tokenBodies.map { $0["nonce"] as? String }, ["nonce-1", "nonce-2"], "the retry uses the nonce issued for the new id")
        XCTAssertEqual(tokenBodies.map { $0["install_id"] as? String }, nonces, "each token call carries the id its nonce was issued for")
        let replaced = await provider.replaced
        XCTAssertEqual(replaced, ["restored-install-id-1"])
    }

    func testARefusedFirstAttestationRetriesOnlyOncePerCall() async throws {
        let stub = StubServer(now: start)
        await stub.failNextToken(status: 401, code: "ATTESTATION_FAILED")
        let provider = RecordingProvider(payload: .appAttest(keyId: "key-1", attestationObject: Data([1]), assertion: nil))
        let transport = try makeTransport(stub: stub, provider: provider)
        await stub.failEveryToken(status: 401, code: "ATTESTATION_FAILED")
        do { _ = try await transport.send(journeyRequest()); XCTFail("expected an error") }
        catch { XCTAssertEqual((error as? LensJourneyError)?.kind, .attestationFailed) }
        let tokenCalls = await stub.calls.filter { $0.path.hasSuffix("install-token") }.count
        XCTAssertEqual(tokenCalls, 2, "one try and one retry as a new install, never a loop")
        let replaced = await provider.replaced
        XCTAssertEqual(replaced.count, 1, "the retry does not start a further install")
    }

    func testOneRefusedAssertionIsToleratedAndTheSecondInARowStartsANewInstall() async throws {
        let stub = StubServer(now: start)
        let provider = RecordingProvider(payload: .appAttest(keyId: "key-1", attestationObject: nil, assertion: Data([9])))
        let store = InMemoryInstallIdStore(installId: "established-install-1")
        let transport = try makeTransport(stub: stub, provider: provider, store: store)

        await stub.failNextToken(status: 401, code: "ATTESTATION_FAILED")
        do { _ = try await transport.send(journeyRequest()); XCTFail("expected an error") } catch { XCTAssertEqual((error as? LensJourneyError)?.kind, .attestationFailed) }
        var replaced = await provider.replaced
        XCTAssertEqual(replaced, [], "a single refusal keeps the install and its key")
        XCTAssertEqual(store.load(), "established-install-1")

        await stub.failNextToken(status: 401, code: "ATTESTATION_FAILED")
        let status = try await transport.send(journeyRequest()).status              // second refusal in a row: new install, retried in the call
        XCTAssertEqual(status, 200)
        replaced = await provider.replaced
        XCTAssertEqual(replaced, ["established-install-1"])
        XCTAssertNotEqual(store.load(), "established-install-1")
    }

    func testASuccessResetsTheRefusedRefreshCount() async throws {
        let stub = StubServer(now: start, lifetime: 3600)
        let clock = TestClock(start)
        let provider = RecordingProvider(payload: .appAttest(keyId: "key-1", attestationObject: nil, assertion: Data([9])))
        let transport = try makeTransport(stub: stub, provider: provider, store: InMemoryInstallIdStore(installId: "established-install-1"), clock: clock)
        await stub.failNextToken(status: 401, code: "ATTESTATION_FAILED")
        do { _ = try await transport.send(journeyRequest()); XCTFail("expected an error") } catch {}
        _ = try await transport.send(journeyRequest())                              // mints fine
        clock.set(start.addingTimeInterval(3600 - 200))
        await stub.failNextToken(status: 401, code: "ATTESTATION_FAILED")
        _ = try await transport.send(journeyRequest())                              // refresh refused, old token used
        let replaced = await provider.replaced
        XCTAssertEqual(replaced, [], "two refusals with a success between them do not end the install")
    }

    func testAPlayIntegrityRefusalNeverStartsANewInstall() async throws {
        let stub = StubServer(now: start)
        await stub.failNextToken(status: 401, code: "ATTESTATION_FAILED")
        let provider = RecordingProvider(payload: .playIntegrity(token: "t"))
        let store = InMemoryInstallIdStore(installId: "established-install-1")
        let transport = try makeTransport(stub: stub, provider: provider, store: store)
        do { _ = try await transport.send(journeyRequest()); XCTFail("expected an error") } catch {}
        let replaced = await provider.replaced
        XCTAssertEqual(replaced, []); XCTAssertEqual(store.load(), "established-install-1")
    }

    // MARK: nothing secret is printed

    func testPayloadsAndRequestsDoNotPrintTheirSecrets() {
        let request = TransportRequest(method: "POST", path: "/x", headers: ["X-API-Key": "key-secret-1", "X-CS-Install-Token": "tok-secret"], body: Data("body".utf8))
        let text = [String(describing: request), "\(request)", String(reflecting: AttestationPayload.debug(challenge: "chal-secret")),
                    String(describing: AttestationPayload.playIntegrity(token: "pi-secret")),
                    String(describing: AttestationPayload.appAttest(keyId: "key-secret", attestationObject: Data([1]), assertion: nil))].joined(separator: " ")
        for secret in ["key-secret-1", "tok-secret", "chal-secret", "pi-secret", "key-secret"] { XCTAssertFalse(text.contains(secret), secret) }
    }

    // MARK: debug provider

    #if DEBUG
    func testTheDebugProviderEchoesTheChallengeAndNothingElse() async throws {
        let payload = try await DebugAttestationProvider().attest(challenge: "abc", installId: "install-id-000001")
        XCTAssertEqual(payload, .debug(challenge: "abc"))
    }
    #endif

    // The absence of `DebugAttestationProvider` from a Release build is proved on the built objects by
    // scripts/check-release-has-no-debug-provider.sh (a runtime lookup by name cannot show it), and the test target builds and runs in a Release
    // configuration (`swift test -c release -Xswiftc -enable-testing`) because nothing outside `#if DEBUG` names the type.

    func testTheEchoChallengeTestProviderMatchesWhatTheDebugProviderSends() async throws {
        // The tests' own stand-in (used where a provider is needed but not the SDK's debug type) sends the same `.debug` payload.
        let payload = try await EchoChallengeProvider().attest(challenge: "abc", installId: "install-id-000001")
        XCTAssertEqual(payload, .debug(challenge: "abc"))
    }

    // MARK: through the real LensJourney

    func testLensJourneyStartRunsThroughTheMobileTransport() async throws {
        let stub = StubServer(now: start)
        let c = try config(key: "cspk_live_abc123")
        let transport = try MobileKeyTransport(config: c, transport: stub, clock: { self.start })
        let journey = LensJourney(config: try JourneyConfig(), transport: transport)
        let state = try await journey.start(category: "single-vision", frame: FrameRef(sku: "S-1"), vision: .distance)
        XCTAssertEqual(state.terminal, .choice)
        let evaluateCalls = await stub.calls
        let evaluate = try XCTUnwrap(evaluateCalls.last)
        XCTAssertEqual(evaluate.path, "/api/v1/lens-journey/evaluate")
        XCTAssertEqual(evaluate.headers["X-CS-Install-Token"], "token-1")
    }

    // MARK: helpers

    private func config(key: String, provider: AttestationProvider = EchoChallengeProvider(), store: InstallIdStore = InMemoryInstallIdStore()) throws -> MobileKeyConfig {
        try MobileKeyConfig(mobileKey: key, baseURL: base, attestationProvider: provider, installIdStore: store)
    }

    private func makeTransport(stub: StubServer, provider: AttestationProvider, store: InstallIdStore = InMemoryInstallIdStore(), clock: TestClock? = nil) throws -> MobileKeyTransport {
        let now = clock ?? TestClock(start)
        return try MobileKeyTransport(config: config(key: "cspk_live_abc123", provider: provider, store: store), transport: stub, clock: { now.now })
    }

    private func journeyRequest(body: String = "{}") -> TransportRequest {
        TransportRequest(method: "POST", path: "/api/v1/lens-journey/evaluate", headers: ["X-Client-Id": "client_123"], body: Data(body.utf8), contentType: "application/json")
    }

    private func json(_ data: Data?) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(data)) as? [String: Any]) }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock(); private var value: Date
    init(_ date: Date) { value = date }
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ date: Date) { lock.lock(); value = date; lock.unlock() }
}

private actor RecordingProvider: AttestationProvider {
    struct Call: Equatable { let challenge: String; let installId: String }
    private(set) var calls: [Call] = []
    private(set) var accepted: [String] = []
    private(set) var rejected: [String] = []
    private(set) var replaced: [String] = []
    private let payload: AttestationPayload
    init(payload: AttestationPayload) { self.payload = payload }
    func attest(challenge: String, installId: String) async throws -> AttestationPayload { calls.append(Call(challenge: challenge, installId: installId)); return payload }
    func attestationAccepted(installId: String) async { accepted.append(installId) }
    func attestationRejected(installId: String) async { rejected.append(installId) }
    func installIdReplaced(_ oldInstallId: String) async { replaced.append(oldInstallId) }
}

private struct ThrowingProvider: AttestationProvider {
    let error: Error
    func attest(challenge: String, installId: String) async throws -> AttestationPayload { throw error }
}

/// A scripted VARAi server: nonce and token routes mint "nonce-N" / "token-N", journey routes answer a choice step.
private actor StubServer: Transport {
    private(set) var calls: [TransportRequest] = []
    private(set) var mintCount = 0
    private var nonceCount = 0
    private let now: Date, lifetime: TimeInterval, mintDelay: UInt64
    private var nonceFailure: (Int, String?)?, tokenFailure: (Int, String?)?, garble = false
    private var rejectedTokens: [String: String] = [:], rejectAllCode: String?
    private var nextTokenReply: [String: Any]?
    private var everyTokenFailure: (Int, String?)?
    var legacyEnvelope = false

    init(now: Date, lifetime: TimeInterval = 3600, mintDelayNanoseconds: UInt64 = 0) { self.now = now; self.lifetime = lifetime; self.mintDelay = mintDelayNanoseconds }
    func failNextNonce(status: Int, code: String? = nil) { nonceFailure = (status, code) }
    func failNextToken(status: Int, code: String) { tokenFailure = (status, code) }
    func failEveryToken(status: Int, code: String) { everyTokenFailure = (status, code) }
    func garbleNextToken() { garble = true }
    func replyToNextToken(with object: [String: Any]) { nextTokenReply = object }
    func useLegacyEnvelope() { legacyEnvelope = true }
    func rejectJourneyToken(_ token: String, code: String) { rejectedTokens[token] = code }
    func rejectAllJourneyTokens(code: String) { rejectAllCode = code }

    func send(_ request: TransportRequest) async throws -> TransportResponse {
        calls.append(request)
        if request.path.hasSuffix("/install-nonce") {
            if mintDelay > 0 { try await Task.sleep(nanoseconds: mintDelay) }
            if let (status, code) = nonceFailure { nonceFailure = nil; return error(status, code) }
            nonceCount += 1
            return ok(["nonce": "nonce-\(nonceCount)", "challenge": "challenge-\(nonceCount)", "expires_at": iso(now.addingTimeInterval(300))])
        }
        if request.path.hasSuffix("/install-token") {
            if let (status, code) = tokenFailure { tokenFailure = nil; return error(status, code) }
            if let (status, code) = everyTokenFailure { return error(status, code) }
            if let reply = nextTokenReply { nextTokenReply = nil; return ok(reply) }
            if garble { garble = false; return TransportResponse(status: 200, body: Data("{\"install_token\":5}".utf8)) }
            mintCount += 1
            return ok(["install_token": "token-\(mintCount)", "expires_at": iso(now.addingTimeInterval(lifetime)), "scopes": ["lens:journey"]])
        }
        let token = request.headers["X-CS-Install-Token"] ?? ""
        if request.headers["X-Slow"] != nil { try await Task.sleep(nanoseconds: 150_000_000) }
        if let code = rejectAllCode ?? rejectedTokens[token] { return error(401, code) }
        return TransportResponse(status: 200, body: Data("{\"workflow_version\":\"1\",\"category\":\"single-vision\",\"terminal\":\"choice\",\"step\":{\"id\":\"n\",\"type\":\"choice\",\"label\":\"L\",\"selection_mode\":\"single\",\"options\":[{\"id\":\"o\",\"label\":\"o\",\"enabled\":true,\"recommended\":false}]},\"selections\":{},\"auto_selected\":[],\"violations\":[],\"settings_warnings\":[]}".utf8))
    }

    private func ok(_ object: [String: Any]) -> TransportResponse { TransportResponse(status: 200, body: try! JSONSerialization.data(withJSONObject: object)) }
    private func error(_ status: Int, _ code: String?) -> TransportResponse {
        // The real mint and token errors are Surface C: the code is in `error`, there is no `code` field. Journey routes may still answer
        // the legacy `{ success: false, error, code }` envelope (useLegacyEnvelope).
        var o: [String: Any] = ["error": code ?? "ERR", "message": "stub", "request_id": "req-1"]
        if legacyEnvelope, let code { o = ["success": false, "error": "Unauthorized", "code": code] }
        return TransportResponse(status: status, body: try! JSONSerialization.data(withJSONObject: o))
    }
    /// Like the server's `toISOString()`: always three fraction digits (`2026-11-13T10:00:00.000Z`).
    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}


/// A test double that answers an attestation challenge with the unsigned `.debug` payload, like the SDK's DEBUG-only `DebugAttestationProvider`,
/// but defined here so the tests build and run in a Release configuration too.
struct EchoChallengeProvider: AttestationProvider {
    func attest(challenge: String, installId: String) async throws -> AttestationPayload { .debug(challenge: challenge) }
}
