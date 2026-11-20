import LensJourney

// The debug provider is not part of the core product. It must not compile without linking LensJourneyDebugAttestation.
public func sneaky() -> AttestationProvider { DebugAttestationProvider() }
