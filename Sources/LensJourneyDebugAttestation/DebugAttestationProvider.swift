import Foundation
import LensJourney

/// Staging-only attestation for simulator runs, CI and staging builds. It sends the server's challenge back unsigned. A production VARAi server
/// refuses a `debug` binding when it is issued and again when it is used, so this provider only ever works against staging, test or development
/// servers.
///
/// It lives in its own product, `LensJourneyDebugAttestation`, and it is the ONLY way to make a debug attestation payload. The core `LensJourney`
/// product has no such case and no such API, so an app target that does not link this product cannot send one at all. Link it only into your
/// debug and staging targets, never into the production target.
///
/// The type works in both Debug and Release configurations, so a staging TestFlight build (Release) can use it.
public struct DebugAttestationProvider: AttestationProvider {
    public init() {}
    public func attest(challenge: String, installId: String) async throws -> AttestationPayload { Self.payload(challenge: challenge) }

    /// The unsigned payload for a challenge. For tests and custom providers in debug targets.
    public static func payload(challenge: String) -> AttestationPayload {
        .restricted(RestrictedAttestation(field: "debug", value: ["challenge": challenge]))
    }
}
