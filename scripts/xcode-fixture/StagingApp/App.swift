import SwiftUI
import LensJourney
import LensJourneyDebugAttestation

// A staging app: opted in by linking the debug product. It really calls the provider so the optimizer cannot drop it.
@main struct StagingApp: App {
    let provider: AttestationProvider = DebugAttestationProvider()
    var body: some Scene {
        WindowGroup { Text("staging").task { _ = try? await provider.attest(challenge: "c", installId: "install-id-000001") } }
    }
}
