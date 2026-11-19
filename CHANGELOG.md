# Changelog

All notable changes to the Lens Journey Swift SDK. Versions are `0.x`: the API can change in a minor release (see the README).

## 0.4.0 (pre-release 0.x, unpublished)

- **Breaking, source, security:** the core `LensJourney` product no longer has any way to make or send a debug attestation. `AttestationPayload.debug(challenge:)` is removed and `DebugAttestationProvider` moves out of the core product into a new opt-in product, **`LensJourneyDebugAttestation`**. Staging, simulator and staging-TestFlight targets add that product; production targets do not link it. (A first attempt compiled the provider only under `#if DEBUG`, but a package cannot control its consumers' build configuration, a Release build could still implement `AttestationProvider` and send `.debug`, and the type was still offered by the core product.)
- New: `AttestationPayload.restricted(RestrictedAttestation)`. `RestrictedAttestation` has no public initializer and no public fields (`package` access), so apps outside the package cannot create or read one. An exhaustive `switch` over `AttestationPayload` needs the new case.
- New: the transport sends a restricted proof only if it was created in the `LensJourneyDebugAttestation` module; any other restricted proof is refused with `.attestationFailed` (`ATTESTATION_PAYLOAD_NOT_ALLOWED`) before `install-token` is called.
- New: `DebugAttestationProvider.payload(challenge:)` (in `LensJourneyDebugAttestation`) for tests and custom providers in debug targets. `DebugAttestationProvider` itself works in Debug and Release when linked.
- New: `scripts/check-debug-attestation-boundary.sh` (replaces `scripts/check-release-has-no-debug-provider.sh`): binary check that the core Release object has no `DebugAttestationProvider`, compile-fail checks from an app outside the package (`.debug`, the provider, forging and reading a `RestrictedAttestation`), and a check that an app linking the debug product builds and runs in Debug and Release.
- `LensJourney.version` is `"0.4.0"`. Not tagged or released: the maintainers publish the version.

## 0.3.0 (pre-release 0.x, unpublished)

- **New, the headline:** the app can talk to VARAi directly with an attested mobile publishable key (`cspk_...`) instead of through a merchant proxy. The merchant's platform prices the cart; the app only passes the configuration id and the session id (ADR-369).
- New: `MobileKeyConfig(mobileKey:baseURL:attestationProvider:installIdStore:allowInsecureHTTP:)`. It throws `.invalidConfiguration` for a secret `cs_` key (code `SECRET_KEY_IN_APP`, the message says secret keys must never ship in an app) and for anything that is not `cspk_` (`INVALID_MOBILE_KEY`). There is no default base URL. Its description never prints the key.
- New: `MobileKeyTransport`, a `Transport` that runs `install-nonce`, asks the provider to attest over the challenge, exchanges the proof at `install-token`, keeps the token in memory, replaces it about 5 minutes before it expires, sends it as `X-CS-Install-Token`, and mints once and retries once on `401 INSTALL_TOKEN_INVALID`. Concurrent calls share one mint, and a failed refresh falls back to a token that is still valid. `LensJourney.mobile(config:mobileKey:)` builds a journey on it.
- New: `AttestationProvider` (`attest(challenge:installId:)`, plus optional `attestationAccepted` and `attestationRejected`), `AttestationPayload` (`.appAttest`, `.playIntegrity`, `.debug`), `InstallIdStore` with `InMemoryInstallIdStore` (the default) and `UserDefaultsInstallIdStore`.
- New: `AppAttestProvider` (`DCAppAttestService`, iOS 14+; key id in the Keychain, kept only after the server accepts it; an assertion on every refresh), with `AppAttestClient` and `AppAttestKeyStore` seams. It throws `.attestationFailed` (`ATTESTATION_UNAVAILABLE`) where App Attest is unsupported.
- New: `DebugAttestationProvider`, **staging only**: a production server refuses a debug binding when it is issued and when it is used.
- New: App Attest recovery. A refused first attestation, or two refused assertions in a row, starts a new install (a new install id) and mints once more in the same call (the server accepts a new attestation only for an install with no accepted key, and answers every failure with the same `401`). One refused assertion keeps the key. `AttestationProvider` gained `installIdReplaced(_:)` (default no-op), and `AppAttestProvider.attestationRejected` no longer drops an accepted key.
- New: a failed refresh is not retried on every call; the transport waits `MobileKeyTransport.refreshRetryDelay` (30 s) while the old token is valid.
- New: `AttestationPayload` and `TransportRequest` print `<redacted>` and header names only, so a log line cannot carry a key, token, challenge or proof.
- **Breaking, source:** `LensJourneyError.Kind` gained `.invalidConfiguration`, `.attestationFailed` and `.mobileChannelDisabled`. An exhaustive `switch` over `Kind` needs new cases.
- **Deprecated:** the merchant-proxy model (`URLSessionTransport` against a proxy that holds a secret key). It keeps working unchanged. The README now leads with the mobile key.
- Docs: how the app hands `final.id` and `sessionId` to the merchant's cart without pricing it, and the Magento cart handoff (`POST /rest/V1/commerce-studio/lens-journey/cart` and the guest variant).
- `LensJourney.version` is `"0.3.0"`.

## 0.2.0 (pre-release 0.x)

- **Breaking, source:** `LensConfiguration.subtotal` is `Decimal?`, no longer `Double?`. The old type could not decode the server's string subtotal at all, so `finish()` threw on the first real success. 0.1.0 still has `Double?`; 0.2.0 is the first version that carries `Decimal?`.
- What 0.2.0 changes on top of the earlier `Decimal` subtotal: the decoder keeps the server's exact text (`subtotalString`) and encodes it back, `LensConfiguration` encodes `subtotal` as the server's string, and the decoder is stricter (below). No public iOS type was removed; the earlier `decodeDecimal` was private.
- **Breaking, behaviour:** `subtotal` strings are validated as plain decimals of at most 40 characters. A string with surrounding whitespace is now rejected (the earlier decoder trimmed it), and so are an exponent form, a trailing newline and anything longer than 40 characters. All of these throw `.malformedResponse` from `finish()`.
- A numeric `subtotal` is still accepted, through `Double` (see Price above); one `Decimal` cannot hold, or longer than 40 characters, is `.malformedResponse`.
- **Breaking, source:** `LensJourneyError.Kind` gained `.malformedResponse`. An exhaustive `switch` over `Kind` needs a new case. A 2xx body that cannot be decoded (evaluate, finish, scan) now throws it instead of a raw `DecodingError`; this includes a malformed `subtotal`, `subtotal_minor` or `currency_decimals`.
- **Breaking, source:** `LensConfiguration` has an explicit `init(from:)`/`encode(to:)` instead of a synthesised one. `inheritedFromPartner` and `prescriptionOnFile` default to `false` when absent.
- **Breaking, behaviour:** `JourneyConfig.init` validates `brand` and throws `.invalidRequest` for an invalid one.
- New on `LensConfiguration`: `subtotalString`, `subtotalMinor`, `currencyDecimals`, `priceBasis`, `priceBasisNote`, `status`, `isQuote`, `currencyMinorUnitDigits`, `subtotalMinorUnits`.
- New: `JourneyConfig.brand`, sent on `/evaluate` and `/configurations` only when set; `LensJourney.version`.
- **Earlier unpublished change, not part of this release's diff:** `URLSessionTransport.init(baseURL:allowInsecureHTTP:headerProvider:)` already `throws` (it refuses a non-https base URL, code `INSECURE_BASE_URL`). Any early caller written against the older non-throwing init must now write `try URLSessionTransport(...)`. Pass `allowInsecureHTTP: true` only in a debug build.
- `scanPrescription` is now exclusive with the other stateful calls (`.busy`).
- `.invalidState` and client-side `.invalidRequest` errors now carry codes (`INVALID_STATE`, `INVALID_REQUEST`).
- Redirects are never followed (the transport has always refused them; it is now tested).
- `swift test` is run in debug and release on two pinned Xcode toolchains (this repo has no CI for it; run it before a release).

## 0.1.0

- First pre-release.
