import SwiftUI
import LensJourney

// A production app: the core product only, with the App Attest provider.
@main struct ProductionApp: App {
    let provider: AttestationProvider = AppAttestProvider()
    var body: some Scene { WindowGroup { Text("production \(LensJourney.version)") } }
}
