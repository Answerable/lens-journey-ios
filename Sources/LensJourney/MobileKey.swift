import Foundation

/// Configuration for talking to VARAi directly with an attested mobile publishable key.
///
/// The key must be a publishable mobile key (`cspk_...`). A secret key (`cs_...`) must never ship in an app: `init` refuses it, and
/// refuses anything that is not a `cspk_` key, with `LensJourneyError.Kind.invalidConfiguration`.
public struct MobileKeyConfig: Sendable, CustomStringConvertible {
    public let mobileKey: String
    /// The VARAi API base URL for the environment this key belongs to (https). There is deliberately no default.
    public let baseURL: URL
    public let attestationProvider: AttestationProvider
    /// Where the install id lives. The default is in memory, so a new id (and a new attestation) is made on every launch:
    /// give the app a persistent store (`UserDefaultsInstallIdStore`, or your own).
    public let installIdStore: InstallIdStore
    /// Debug opt-in (a simulator reaching http://localhost). Never set it in a release build.
    public let allowInsecureHTTP: Bool

    public init(mobileKey: String, baseURL: URL, attestationProvider: AttestationProvider, installIdStore: InstallIdStore = InMemoryInstallIdStore(), allowInsecureHTTP: Bool = false) throws {
        if mobileKey.lowercased().hasPrefix("cs_") {
            throw LensJourneyError(kind: .invalidConfiguration, code: "SECRET_KEY_IN_APP", message: "A secret key (cs_...) must never ship in an app. Use a mobile publishable key (cspk_...) and let VARAi attest the install.")
        }
        guard mobileKey.hasPrefix("cspk_"), mobileKey.count > 5, mobileKey.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else {
            throw LensJourneyError(kind: .invalidConfiguration, code: "INVALID_MOBILE_KEY", message: "mobileKey must be a mobile publishable key starting with cspk_")
        }
        self.mobileKey = mobileKey; self.baseURL = baseURL; self.attestationProvider = attestationProvider
        self.installIdStore = installIdStore; self.allowInsecureHTTP = allowInsecureHTTP
    }

    /// The key is never printed.
    public var description: String { "MobileKeyConfig(baseURL: \(baseURL.absoluteString), mobileKey: <redacted>)" }
}

/// Where the SDK keeps the install id (a random id for one app installation). Persist it across launches and drop it when the app is
/// uninstalled; `UserDefaultsInstallIdStore` does both. The in-memory default forgets it on every launch.
public protocol InstallIdStore: Sendable {
    func load() -> String?
    func save(_ installId: String)
}

public final class InMemoryInstallIdStore: InstallIdStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    public init(installId: String? = nil) { value = installId }
    public func load() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    public func save(_ installId: String) { lock.lock(); defer { lock.unlock() }; value = installId }
}

/// Persists the install id in `UserDefaults`. It is removed with the app, which matches App Attest keys (also lost on reinstall).
public final class UserDefaultsInstallIdStore: InstallIdStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    public init(defaults: UserDefaults = .standard, key: String = "ai.varai.lensjourney.install-id") { self.defaults = defaults; self.key = key }
    public func load() -> String? { defaults.string(forKey: key) }
    public func save(_ installId: String) { defaults.set(installId, forKey: key) }
}

/// The platform proof the server checks. The case decides which field of `POST /install-token` carries it.
///
/// This core product has no unsigned or "debug" proof, and no public way to make one. The `restricted` case exists so that a separate,
/// opt-in product of this package (`LensJourneyDebugAttestation`) can hand the transport a proof of a kind the production product does not
/// offer. Code outside this package cannot construct a `RestrictedAttestation`.
public enum AttestationPayload: Equatable, Sendable, CustomStringConvertible {
    /// App Attest. Send `attestationObject` on the first issue for a key, or `assertion` on a refresh.
    case appAttest(keyId: String, attestationObject: Data?, assertion: Data?)
    /// A Play Integrity token (Android).
    case playIntegrity(token: String)
    /// A proof that only the opt-in `LensJourneyDebugAttestation` product can make. See `RestrictedAttestation`.
    case restricted(RestrictedAttestation)

    /// Never prints the proof, the token or the challenge.
    public var description: String {
        switch self {
        case .appAttest: return "AttestationPayload.appAttest(<redacted>)"
        case .playIntegrity: return "AttestationPayload.playIntegrity(<redacted>)"
        case .restricted: return "AttestationPayload.restricted(<redacted>)"
        }
    }
}

/// A proof that the core product cannot make. It is opaque and has no public initializer: its fields and its initializer use the `package`
/// access level, so only targets of this Swift package (the core product and `LensJourneyDebugAttestation`) can create or read one. An app
/// that depends on the package from outside it cannot name the initializer, so it cannot forge one.
///
/// As a second line of defence the transport sends a restricted proof only if it was created in a source file of the
/// `LensJourneyDebugAttestation` module (`#fileID`); anything else is refused with `ATTESTATION_PAYLOAD_NOT_ALLOWED` and nothing is sent.
public struct RestrictedAttestation: Equatable, Sendable, CustomStringConvertible {
    /// The only module whose proofs the transport will send.
    package static let allowedOriginPrefix = "LensJourneyDebugAttestation/"
    package let field: String
    package let value: [String: String]
    package let origin: String
    package init(field: String, value: [String: String], origin: String = #fileID) {
        self.field = field; self.value = value; self.origin = origin
    }
    public var description: String { "RestrictedAttestation(<redacted>)" }
}

/// Produces the proof that this is a genuine install of the app. `challenge` comes from the server (bound to the install id);
/// the proof must be made over it.
///
/// Throw `LensJourneyError(kind: .attestationFailed, ...)` when the device cannot attest; any other error is wrapped as one.
public protocol AttestationProvider: Sendable {
    func attest(challenge: String, installId: String) async throws -> AttestationPayload
    /// The server accepted the attestation and issued a token. Providers that stage state (a new key) commit it here.
    func attestationAccepted(installId: String) async
    /// The server refused the attestation. Providers drop state that was staged for this attempt (a new key that was never accepted).
    /// Keep a key that the server already accepted: the refusal may be transient, and the transport ends the install by itself when
    /// the refusals repeat (`installIdReplaced`).
    func attestationRejected(installId: String) async
    /// The transport has started a new install (a new install id) because the server will not attest this one again. Drop everything
    /// kept for `oldInstallId`, including an accepted key.
    func installIdReplaced(_ oldInstallId: String) async
}

public extension AttestationProvider {
    func attestationAccepted(installId: String) async {}
    func attestationRejected(installId: String) async {}
    func installIdReplaced(_ oldInstallId: String) async {}
}
