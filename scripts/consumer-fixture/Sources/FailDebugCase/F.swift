import LensJourney

// The pre-0.4.0 way: a custom provider returning `.debug(challenge:)`. It must not compile against the core product.
public struct Sneaky: AttestationProvider {
    public init() {}
    public func attest(challenge: String, installId: String) async throws -> AttestationPayload { .debug(challenge: challenge) }
}
