import SwiftUI
import LensJourney

// Forging a sealed payload with only the core product linked. Must not compile.
struct Forge: AttestationProvider {
    func attest(challenge: String, installId: String) async throws -> AttestationPayload {
        .restricted(RestrictedAttestation(field: "debug", value: ["challenge": challenge]))
    }
}
@main struct FailRestrictedApp: App {
    var body: some Scene { WindowGroup { Text("x") } }
}
