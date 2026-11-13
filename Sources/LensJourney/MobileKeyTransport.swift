import Foundation

/// A `Transport` that talks to VARAi directly with an attested mobile publishable key.
///
/// On the first journey call (and whenever the token is about to expire) it runs `install-nonce`, asks the `AttestationProvider`
/// to attest over the server's challenge, and exchanges that for a short-lived install token via `install-token`. Journey calls
/// carry the token in `X-CS-Install-Token`; the mobile key itself is only sent on the two mint calls.
///
/// - The token is kept in memory and replaced about 5 minutes before it expires (or half-way through a token that lives under
///   10 minutes). If that refresh fails while the old token is still valid, the old token is used.
/// - A `401` with code `INSTALL_TOKEN_INVALID` (revoked, or expired early) mints a new token once and retries the call once.
/// - A failed refresh is not retried on every call: while the old token is still valid the transport waits `refreshRetryDelay`
///   before it tries again.
/// - App Attest recovery: the server accepts a new attestation only for an install that has no accepted key yet. If it refuses a
///   first attestation (a restored backup whose id outlived its Keychain key, or an accepted attestation whose answer was lost), the
///   transport starts a new install (new install id) and mints once more. If it refuses two refresh assertions in a row, it does the
///   same. One refused assertion alone is tolerated: the key stays, because the server answers every failure with the same 401.
/// - Concurrent calls share one mint.
public actor MobileKeyTransport: Transport {
    /// How long before expiry the token is replaced.
    public static let refreshLeadTime: TimeInterval = 300
    /// After a failed refresh (with the old token still valid) the next attempt waits this long.
    public static let refreshRetryDelay: TimeInterval = 30

    private struct CachedToken { let value: String; let refreshAt: Date; let expiresAt: Date }

    private let config: MobileKeyConfig
    private let inner: Transport
    private let clock: @Sendable () -> Date
    private var cached: CachedToken?
    private var minting: Task<CachedToken, Error>?
    private var installId: String?
    private var refreshBackoffUntil: Date?
    private var refusedRefreshes = 0
    private var installRotatedDuringMint = false

    /// - Parameters:
    ///   - transport: Sends the requests. `nil` (the default) uses `URLSessionTransport` against `config.baseURL`, which refuses a
    ///     non-https URL unless `config.allowInsecureHTTP` is set. Tests inject a stub.
    ///   - clock: The current time; tests inject a fake.
    public init(config: MobileKeyConfig, transport: Transport? = nil, clock: @escaping @Sendable () -> Date = Date.init) throws {
        self.config = config
        self.inner = try transport ?? URLSessionTransport(baseURL: config.baseURL, allowInsecureHTTP: config.allowInsecureHTTP)
        self.clock = clock
    }

    public func send(_ request: TransportRequest) async throws -> TransportResponse {
        let token = try await currentToken()
        let first = try await inner.send(authorized(request, token))
        guard first.status == 401, errorCode(first) == "INSTALL_TOKEN_INVALID" else { return first }
        let fresh = try await tokenAfterRejecting(token)
        return try await inner.send(authorized(request, fresh))
    }

    // MARK: token cache

    private func currentToken() async throws -> String {
        if let cached {
            let now = clock()
            if now < cached.refreshAt { return cached.value }
            if let until = refreshBackoffUntil, now < until, now < cached.expiresAt { return cached.value }
        }
        do {
            let token = try await mintShared().value
            refreshBackoffUntil = nil
            return token
        }
        catch is CancellationError { throw CancellationError() }
        catch {
            // A failed refresh is not a failure while the old token still works.
            if let cached, clock() < cached.expiresAt {
                refreshBackoffUntil = clock().addingTimeInterval(Self.refreshRetryDelay)
                return cached.value
            }
            throw error
        }
    }

    private func tokenAfterRejecting(_ stale: String) async throws -> String {
        // Another call may already have replaced the rejected token.
        if let cached, cached.value != stale, clock() < cached.expiresAt { return cached.value }
        if cached?.value == stale { cached = nil }
        return try await mintShared().value
    }

    private func mintShared() async throws -> CachedToken {
        if let minting { return try await minting.value }
        let task = Task { try await self.mint() }
        minting = task
        defer { minting = nil }
        return try await task.value
    }

    // MARK: mint

    private func mint() async throws -> CachedToken {
        installRotatedDuringMint = false
        do { return try await mintOnce(allowNewInstall: true) }
        catch {
            // The server refused an attestation that a new install can fix: try once more as a new install. That retry never starts
            // a further install, so a server that keeps refusing costs one new install id per call, not a chain of them.
            guard installRotatedDuringMint, !(error is CancellationError) else { throw error }
            installRotatedDuringMint = false
            return try await mintOnce(allowNewInstall: false)
        }
    }

    private func mintOnce(allowNewInstall: Bool) async throws -> CachedToken {
        let installId = resolveInstallId()
        let provider = config.attestationProvider
        let platform = "ios"

        let nonceResponse = try await post("install-nonce", ["install_id": installId, "platform": platform])
        let nonce = try decode(NonceResponse.self, from: nonceResponse)

        let payload: AttestationPayload
        do { payload = try await provider.attest(challenge: nonce.challenge, installId: installId) }
        catch let error as LensJourneyError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw LensJourneyError(kind: .attestationFailed, code: "ATTESTATION_FAILED", message: "The device could not attest this install: \(error.localizedDescription)") }

        var body: [String: Any] = ["install_id": installId, "platform": platform, "nonce": nonce.nonce]
        switch payload {
        case let .appAttest(keyId, attestationObject, assertion):
            var ios: [String: Any] = ["key_id": keyId]
            if let attestationObject { ios["attestation_object"] = attestationObject.base64EncodedString() }
            if let assertion { ios["assertion"] = assertion.base64EncodedString() }
            body["ios"] = ios
        case let .playIntegrity(token): body["android"] = ["integrity_token": token]
        case let .debug(challenge): body["debug"] = ["challenge": challenge]
        }

        let tokenResponse: TransportResponse
        do { tokenResponse = try await post("install-token", body) }
        catch let error as LensJourneyError {
            if error.kind == .attestationFailed {
                await provider.attestationRejected(installId: installId)
                if allowNewInstall, case let .appAttest(_, _, assertion) = payload, shouldStartNewInstall(afterRefusedAssertion: assertion != nil) {
                    await startNewInstall(replacing: installId)
                }
            }
            throw error
        }
        let issued = try decode(TokenResponse.self, from: tokenResponse)
        guard let expiresAt = parseDate(issued.expiresAt), !issued.installToken.isEmpty else {
            throw LensJourneyError(kind: .malformedResponse, code: "MALFORMED_RESPONSE", message: "The server issued an install token the SDK could not read")
        }
        let lifetime = max(0, expiresAt.timeIntervalSince(clock()))
        let token = CachedToken(value: issued.installToken, refreshAt: expiresAt.addingTimeInterval(-min(Self.refreshLeadTime, lifetime / 2)), expiresAt: expiresAt)
        cached = token
        refusedRefreshes = 0
        await provider.attestationAccepted(installId: installId)
        return token
    }

    private func post(_ route: String, _ body: [String: Any]) async throws -> TransportResponse {
        let data = try JSONSerialization.data(withJSONObject: body)
        let response = try await inner.send(TransportRequest(method: "POST", path: "/api/v1/lens-journey/\(route)", headers: ["X-API-Key": config.mobileKey], body: data, contentType: "application/json"))
        guard (200...299).contains(response.status) else { throw failure(response) }
        return response
    }

    private func resolveInstallId() -> String {
        if let installId { return installId }
        if let stored = config.installIdStore.load(), stored.range(of: "^[A-Za-z0-9_-]{16,64}$", options: .regularExpression) != nil {
            installId = stored
            return stored
        }
        return newInstallId()
    }

    private func newInstallId() -> String {
        let fresh = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        config.installIdStore.save(fresh)
        installId = fresh
        return fresh
    }

    /// A refused first attestation is treated as an install id that cannot be attested again (the server refuses a new attestation for an
    /// install that already has an accepted key), and a new install is the only recovery. It may also be refused for a reason a new id does
    /// not fix; the retry is then refused too and nothing more is started. A refused assertion may be transient, so the first one is
    /// tolerated and the second in a row ends the install.
    private func shouldStartNewInstall(afterRefusedAssertion: Bool) -> Bool {
        guard afterRefusedAssertion else { return true }
        refusedRefreshes += 1
        return refusedRefreshes >= 2
    }

    private func startNewInstall(replacing old: String) async {
        refusedRefreshes = 0
        _ = newInstallId()
        installRotatedDuringMint = true
        await config.attestationProvider.installIdReplaced(old)
    }

    // MARK: wire

    private func authorized(_ request: TransportRequest, _ token: String) -> TransportRequest {
        var headers = request.headers
        headers["X-CS-Install-Token"] = token
        return TransportRequest(method: request.method, path: request.path, headers: headers, body: request.body, contentType: request.contentType)
    }

    private func errorCode(_ response: TransportResponse) -> String? {
        let envelope = (try? JSONDecoder().decode(ErrorEnvelope.self, from: response.body)) ?? ErrorEnvelope()
        return envelope.code ?? envelope.error
    }

    private func failure(_ response: TransportResponse) -> LensJourneyError {
        let envelope = (try? JSONDecoder().decode(ErrorEnvelope.self, from: response.body)) ?? ErrorEnvelope()
        let code = envelope.code ?? envelope.error
        let kind: LensJourneyError.Kind
        switch response.status {
        case 400: kind = .invalidRequest
        case 401: kind = code == "ATTESTATION_FAILED" ? .attestationFailed : .unauthorized
        case 403: kind = code == "MOBILE_CHANNEL_DISABLED" ? .mobileChannelDisabled : .insufficientScope
        case 429: kind = .rateLimited
        default: kind = .unavailable
        }
        return LensJourneyError(kind: kind, code: code, message: envelope.message ?? envelope.error ?? "Request failed", details: envelope.details, requestId: envelope.requestId, documentationURL: envelope.documentationURL)
    }

    private func decode<T: Decodable>(_ type: T.Type, from response: TransportResponse) throws -> T {
        do { return try JSONDecoder().decode(type, from: response.body) }
        catch { throw LensJourneyError(kind: .malformedResponse, code: "MALFORMED_RESPONSE", message: "The server answered \(response.status) with a body the SDK could not read") }
    }

    private func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter(); plain.formatOptions = [.withInternetDateTime]
        return fractional.date(from: text) ?? plain.date(from: text)
    }
}

private struct NonceResponse: Decodable { let nonce: String; let challenge: String }
private struct TokenResponse: Decodable {
    let installToken: String; let expiresAt: String; let scopes: [String]?
    enum CodingKeys: String, CodingKey { case installToken = "install_token"; case expiresAt = "expires_at"; case scopes }
}

public extension LensJourney {
    /// A journey that talks to VARAi directly with an attested mobile key. Throws `.invalidConfiguration` never for the key itself
    /// (that is checked when `MobileKeyConfig` is built) but throws for a non-https base URL.
    static func mobile(config: JourneyConfig, mobileKey: MobileKeyConfig, sleep: Sleeper? = nil, clock: @escaping Clock = Date.init) throws -> LensJourney {
        LensJourney(config: config, transport: try MobileKeyTransport(config: mobileKey), sleep: sleep, clock: clock)
    }
}
