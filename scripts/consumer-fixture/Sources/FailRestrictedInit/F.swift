import LensJourney

// Forging the sealed payload from outside the package: the initializer is `package` access.
public struct Sneaky: AttestationProvider {
    public init() {}
    public func attest(challenge: String, installId: String) async throws -> AttestationPayload {
        .restricted(RestrictedAttestation(field: "debug", value: ["challenge": challenge]))
    }
}
