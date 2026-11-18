#if canImport(DeviceCheck)
import CryptoKit
import DeviceCheck
import Foundation
import Security

/// The three App Attest calls the provider needs. `DeviceCheckAppAttestClient` is the real one; tests inject a fake.
public protocol AppAttestClient: Sendable {
    /// `false` on a simulator, on a Mac without App Attest and on iOS older than 14.
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

public struct DeviceCheckAppAttestClient: AppAttestClient {
    public init() {}
    public var isSupported: Bool { DCAppAttestService.shared.isSupported }
    public func generateKey() async throws -> String { try await DCAppAttestService.shared.generateKey() }
    public func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data { try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash) }
    public func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data { try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash) }
}

/// Where the attested App Attest key id is kept, per install id.
public protocol AppAttestKeyStore: Sendable {
    func keyId(forInstallId installId: String) -> String?
    func save(keyId: String, forInstallId installId: String)
    func remove(installId: String)
}

/// Keeps key ids in the Keychain (this device only, readable after the first unlock).
public final class KeychainAppAttestKeyStore: AppAttestKeyStore, @unchecked Sendable {
    private let service: String
    public init(service: String = "ai.varai.lensjourney.appattest") { self.service = service }

    public func keyId(forInstallId installId: String) -> String? {
        var query = base(installId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(keyId: String, forInstallId installId: String) {
        remove(installId: installId)
        var attributes = base(installId)
        attributes[kSecValueData as String] = Data(keyId.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public func remove(installId: String) { SecItemDelete(base(installId) as CFDictionary) }

    private func base(_ installId: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: installId]
    }
}

/// Apple App Attest (`DCAppAttestService`, iOS 14+).
///
/// First issue for an install: it creates a key, attests it over the server's challenge and sends the attestation object. The key id
/// is only written to the Keychain once the server has accepted it (`attestationAccepted`). Every later token for that install is a
/// refresh: it sends an assertion made with the stored key, with no new key and no round trip to Apple's attestation servers.
/// If the server refuses a first attestation (`attestationRejected`), nothing was stored, so the next attempt attests a fresh key. A key
/// the server already accepted is kept when it refuses one assertion, because that refusal may be transient. When the transport starts a
/// new install (`installIdReplaced`), the key kept for the old install id is dropped.
///
/// `clientDataHash` is the SHA-256 of the UTF-8 bytes of the challenge string the server returned from `install-nonce`.
///
/// On a simulator or any device where App Attest is not supported, `attest` throws `LensJourneyError(kind: .attestationFailed,
/// code: "ATTESTATION_UNAVAILABLE")` without calling Apple. In a DEBUG build use `DebugAttestationProvider` against a staging server there.
public actor AppAttestProvider: AttestationProvider {
    private let client: AppAttestClient
    private let keyStore: AppAttestKeyStore
    private var pending: [String: String] = [:]

    public init(client: AppAttestClient = DeviceCheckAppAttestClient(), keyStore: AppAttestKeyStore = KeychainAppAttestKeyStore()) {
        self.client = client; self.keyStore = keyStore
    }

    public func attest(challenge: String, installId: String) async throws -> AttestationPayload {
        guard client.isSupported else {
            throw LensJourneyError(kind: .attestationFailed, code: "ATTESTATION_UNAVAILABLE", message: "App Attest is not supported on this device (a simulator, or iOS older than 14)")
        }
        let hash = Data(SHA256.hash(data: Data(challenge.utf8)))
        do {
            if let keyId = keyStore.keyId(forInstallId: installId) {
                return .appAttest(keyId: keyId, attestationObject: nil, assertion: try await client.generateAssertion(keyId, clientDataHash: hash))
            }
            let keyId = try await client.generateKey()
            let attestation = try await client.attestKey(keyId, clientDataHash: hash)
            pending[installId] = keyId
            return .appAttest(keyId: keyId, attestationObject: attestation, assertion: nil)
        } catch let error as LensJourneyError {
            throw error
        } catch {
            throw LensJourneyError(kind: .attestationFailed, code: "ATTESTATION_FAILED", message: "App Attest failed: \(error.localizedDescription)")
        }
    }

    public func attestationAccepted(installId: String) async {
        if let keyId = pending.removeValue(forKey: installId) { keyStore.save(keyId: keyId, forInstallId: installId) }
    }

    public func attestationRejected(installId: String) async {
        pending.removeValue(forKey: installId)
    }

    public func installIdReplaced(_ oldInstallId: String) async {
        pending.removeValue(forKey: oldInstallId)
        keyStore.remove(installId: oldInstallId)
    }
}
#endif
