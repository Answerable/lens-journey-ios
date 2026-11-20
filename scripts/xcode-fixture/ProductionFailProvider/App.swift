import SwiftUI
import LensJourney

// Naming the debug provider with only the core product linked. Must not compile.
@main struct FailProviderApp: App {
    let provider: AttestationProvider = DebugAttestationProvider()
    var body: some Scene { WindowGroup { Text("x") } }
}
