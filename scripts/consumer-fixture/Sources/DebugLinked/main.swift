import LensJourney
import LensJourneyDebugAttestation

// A staging or simulator target that opted in by linking the debug product.
let payload = try await DebugAttestationProvider().attest(challenge: "c", installId: "install-id-000001")
print(payload)
