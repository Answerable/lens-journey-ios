#if canImport(DeviceCheck)
import CryptoKit
import XCTest
@testable import LensJourney

final class AppAttestProviderTests: XCTestCase {
    private let installId = "install-id-0000000001"

    func testFirstIssueAttestsANewKeyOverTheHashedChallengeAndKeepsItOnlyAfterAcceptance() async throws {
        let client = FakeAppAttest()
        let store = MemoryKeyStore()
        let provider = AppAttestProvider(client: client, keyStore: store)

        let payload = try await provider.attest(challenge: "challenge-abc", installId: installId)
        XCTAssertEqual(payload, .appAttest(keyId: "key-1", attestationObject: Data("attestation-key-1".utf8), assertion: nil))
        XCTAssertEqual(client.hashes, [Data(SHA256.hash(data: Data("challenge-abc".utf8)))], "clientDataHash is SHA-256 of the challenge string")
        XCTAssertNil(store.keyId(forInstallId: installId), "an unaccepted key is not persisted")

        await provider.attestationAccepted(installId: installId)
        XCTAssertEqual(store.keyId(forInstallId: installId), "key-1")
    }

    func testARefreshSendsAnAssertionWithTheStoredKeyAndMakesNoNewKey() async throws {
        let client = FakeAppAttest()
        let store = MemoryKeyStore()
        store.save(keyId: "key-9", forInstallId: installId)
        let provider = AppAttestProvider(client: client, keyStore: store)

        let payload = try await provider.attest(challenge: "next", installId: installId)
        XCTAssertEqual(payload, .appAttest(keyId: "key-9", attestationObject: nil, assertion: Data("assertion-key-9".utf8)))
        XCTAssertEqual(client.generated, 0)
        XCTAssertEqual(client.attested, 0)
        XCTAssertEqual(client.hashes, [Data(SHA256.hash(data: Data("next".utf8)))], "an assertion is also made over SHA-256 of the challenge string")
    }

    func testAnUnacceptedKeyIsReplacedNotReused() async throws {
        let client = FakeAppAttest()
        let provider = AppAttestProvider(client: client, keyStore: MemoryKeyStore())
        _ = try await provider.attest(challenge: "a", installId: installId)
        let second = try await provider.attest(challenge: "b", installId: installId)
        XCTAssertEqual(second, .appAttest(keyId: "key-2", attestationObject: Data("attestation-key-2".utf8), assertion: nil), "a key Apple already attested cannot be attested again")
    }

    func testARefusedRefreshKeepsTheAcceptedKeyBecauseTheRefusalMayBeTransient() async throws {
        let store = MemoryKeyStore()
        store.save(keyId: "key-9", forInstallId: installId)
        let provider = AppAttestProvider(client: FakeAppAttest(), keyStore: store)
        await provider.attestationRejected(installId: installId)
        XCTAssertEqual(store.keyId(forInstallId: installId), "key-9")
        let payload = try await provider.attest(challenge: "again", installId: installId)
        guard case let .appAttest(keyId, attestationObject, assertion) = payload else { return XCTFail("expected App Attest") }
        XCTAssertEqual(keyId, "key-9"); XCTAssertNil(attestationObject); XCTAssertNotNil(assertion, "the next attempt is still an assertion with the same key")
    }

    func testAReplacedInstallDropsItsKeyAndNothingElse() async throws {
        let store = MemoryKeyStore()
        store.save(keyId: "key-9", forInstallId: installId)
        store.save(keyId: "key-7", forInstallId: "install-id-0000000002")
        let provider = AppAttestProvider(client: FakeAppAttest(), keyStore: store)
        await provider.installIdReplaced(installId)
        XCTAssertNil(store.keyId(forInstallId: installId))
        XCTAssertEqual(store.keyId(forInstallId: "install-id-0000000002"), "key-7")
    }

    func testARefusedFirstAttestationLeavesNothingBehind() async throws {
        let store = MemoryKeyStore()
        let provider = AppAttestProvider(client: FakeAppAttest(), keyStore: store)
        _ = try await provider.attest(challenge: "a", installId: installId)
        await provider.attestationRejected(installId: installId)
        XCTAssertNil(store.keyId(forInstallId: installId))
        await provider.attestationAccepted(installId: installId)
        XCTAssertNil(store.keyId(forInstallId: installId), "a refused key is never persisted afterwards")
    }

    func testAKeyIsPerInstallId() async throws {
        let store = MemoryKeyStore()
        store.save(keyId: "key-9", forInstallId: installId)
        let provider = AppAttestProvider(client: FakeAppAttest(), keyStore: store)
        let other = try await provider.attest(challenge: "c", installId: "install-id-0000000002")
        guard case let .appAttest(keyId, attestationObject, assertion) = other else { return XCTFail("expected App Attest") }
        XCTAssertNotEqual(keyId, "key-9"); XCTAssertNotNil(attestationObject); XCTAssertNil(assertion)
    }

    func testAnUnsupportedDeviceIsATypedErrorAndAppleIsNotCalled() async throws {
        let client = FakeAppAttest(supported: false)
        let provider = AppAttestProvider(client: client, keyStore: MemoryKeyStore())
        do { _ = try await provider.attest(challenge: "c", installId: installId); XCTFail("expected an error") }
        catch {
            let e = error as? LensJourneyError
            XCTAssertEqual(e?.kind, .attestationFailed); XCTAssertEqual(e?.code, "ATTESTATION_UNAVAILABLE")
        }
        XCTAssertEqual(client.generated, 0)
    }

    func testAnAppleErrorIsATypedAttestationError() async throws {
        let client = FakeAppAttest(failure: URLError(.badServerResponse))
        let provider = AppAttestProvider(client: client, keyStore: MemoryKeyStore())
        do { _ = try await provider.attest(challenge: "c", installId: installId); XCTFail("expected an error") }
        catch { XCTAssertEqual((error as? LensJourneyError)?.kind, .attestationFailed); XCTAssertEqual((error as? LensJourneyError)?.code, "ATTESTATION_FAILED") }
    }

    func testTheRealClientReportsSupportWithoutCrashing() {
        _ = DeviceCheckAppAttestClient().isSupported
    }
}

private final class FakeAppAttest: AppAttestClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _generated = 0, _attested = 0, _hashes: [Data] = []
    let isSupported: Bool
    private let failure: Error?
    init(supported: Bool = true, failure: Error? = nil) { isSupported = supported; self.failure = failure }
    var generated: Int { lock.lock(); defer { lock.unlock() }; return _generated }
    var attested: Int { lock.lock(); defer { lock.unlock() }; return _attested }
    var hashes: [Data] { lock.lock(); defer { lock.unlock() }; return _hashes }
    func generateKey() async throws -> String {
        if let failure { throw failure }
        lock.lock(); defer { lock.unlock() }; _generated += 1; return "key-\(_generated)"
    }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        lock.lock(); defer { lock.unlock() }; _attested += 1; _hashes.append(clientDataHash); return Data("attestation-\(keyId)".utf8)
    }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        lock.lock(); defer { lock.unlock() }; _hashes.append(clientDataHash); return Data("assertion-\(keyId)".utf8)
    }
}

private final class MemoryKeyStore: AppAttestKeyStore, @unchecked Sendable {
    private let lock = NSLock(); private var keys: [String: String] = [:]
    func keyId(forInstallId installId: String) -> String? { lock.lock(); defer { lock.unlock() }; return keys[installId] }
    func save(keyId: String, forInstallId installId: String) { lock.lock(); keys[installId] = keyId; lock.unlock() }
    func remove(installId: String) { lock.lock(); keys[installId] = nil; lock.unlock() }
}
#endif
