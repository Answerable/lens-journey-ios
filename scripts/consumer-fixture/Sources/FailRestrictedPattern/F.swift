import LensJourney

// Reading what is inside a sealed payload from outside the package: its fields are `package` access.
public func peek(_ payload: AttestationPayload) -> String? {
    if case let .restricted(proof) = payload { return proof.field }
    return nil
}
