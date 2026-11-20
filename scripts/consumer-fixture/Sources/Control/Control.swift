import LensJourney

// What a production app does: only the core product. A custom provider can return the proofs the core product offers.
public struct PlayIntegrityLikeProvider: AttestationProvider {
    public init() {}
    public func attest(challenge: String, installId: String) async throws -> AttestationPayload { .playIntegrity(token: challenge) }
}
public func controlUsesCoreOnly() -> AttestationProvider { AppAttestProvider() }
