# LensJourney for Swift

> **Pre-release (0.x), unpublished.** The API can still change without notice. Pin an exact version.

`LensJourney` is a Foundation-only Swift package for Commerce Studio's server-driven lens journey. It requires iOS 15 or macOS 12 and Swift 5.9. The SDK contains no lens rules and no API secret.

**How the app is authenticated (0.3.0 and later).** The app talks to VARAi directly, with an attested mobile publishable key (`cspk_...`). The merchant's platform prices the cart: the app hands the journey result (`configuration id` and `sessionId`) to the merchant's cart, and the merchant's platform prices it from its own catalogue (ADR-369). The app never prices anything and never holds a secret key. A secret key (`cs_...`) must never ship in an app, and the SDK refuses one.

```swift
// The mobile key comes from your VARAi dashboard. MobileKeyConfig refuses a secret cs_ key and anything that is not cspk_.
let mobile = try MobileKeyConfig(
    mobileKey: appMobileKey,                       // "cspk_..."
    baseURL: apiBaseURL,                           // the VARAi API URL for your environment (https)
    attestationProvider: AppAttestProvider(),      // staging/simulator targets only: DebugAttestationProvider() from the LensJourneyDebugAttestation product
    installIdStore: UserDefaultsInstallIdStore()   // keep the install id across launches
)
let journey = try LensJourney.mobile(config: try JourneyConfig(currency: "USD", store: "us"), mobileKey: mobile)
var state = try await journey.start(category: "single-vision", frame: FrameRef(sku: "FRAME-1"), vision: .distance)
state = try await journey.select(optionId: "anti-reflective")
let final = try await journey.finish() // final.id is the configuration id the app gives to the merchant's cart
```

## Mobile key, attestation and install tokens

> **Needs the server side.** The mobile channel is off by default on the VARAi API (`403 MOBILE_CHANNEL_DISABLED`, typed as `.mobileChannelDisabled`) until VARAi enables it for your tenant and binds your app to a mobile key. Until then use the proxy transport below.

A mobile key alone authorises nothing. `MobileKeyTransport` (what `LensJourney.mobile` uses) exchanges it for a short-lived **install token**:

1. `POST /api/v1/lens-journey/install-nonce` with the install id gives a single-use nonce and a challenge that is bound to this install.
2. The `AttestationProvider` proves the install is a genuine copy of your app over that challenge (App Attest on iOS).
3. `POST /api/v1/lens-journey/install-token` exchanges the proof for an install token (valid for about an hour).
4. Every journey call carries the token in `X-CS-Install-Token`. The mobile key is sent only on the two mint calls.

The token is kept in memory and replaced about 5 minutes before it expires (half-way through a token that lives under 10 minutes). If that refresh fails while the old token still works, the old token is used. If the server answers `401` with code `INSTALL_TOKEN_INVALID` (revoked, or expired early) the SDK mints a new token once and retries that call once. Concurrent calls share one mint. If the refresh keeps failing, the SDK does not try again on every call: it waits 30 seconds (`MobileKeyTransport.refreshRetryDelay`) while the old token is still valid.

**Install id.** A random id for one app installation, made on first use and kept in an `InstallIdStore`. The default `InMemoryInstallIdStore` forgets it on every launch, which means a new attestation on every launch (and a per-device cap you will hit). Use `UserDefaultsInstallIdStore` (removed with the app, like App Attest keys) or your own store.

**`AppAttestProvider`** uses `DCAppAttestService` (iOS 14+). Enable the App Attest capability for your app. The first token for an install creates a key, attests it over the challenge and sends the attestation. The key id is kept in the Keychain only once the server has accepted it; every later token is a refresh that sends an assertion with that key. The server accepts a new attestation only for an install that has no accepted key yet, and answers every failure with the same `401 ATTESTATION_FAILED`. So the SDK recovers like this: a refused **first** attestation (for example an install id restored from a backup while its Keychain key stayed on the old device, or an accepted attestation whose answer was lost) starts a **new install** (a new install id) and mints once more in the same call; one refused **assertion** is tolerated and keeps the key, because it may be transient; a second refused assertion in a row also starts a new install. Each new install counts once against the per-key daily install cap when it is accepted. The hash App Attest signs is the SHA-256 of the UTF-8 challenge string. On a simulator, or anywhere App Attest is unsupported, it throws `LensJourneyError.Kind.attestationFailed` (code `ATTESTATION_UNAVAILABLE`); there is no fallback to a weaker proof.

**`DebugAttestationProvider` is for staging only, and it is a separate product.** It sends the challenge back unsigned. A production VARAi server refuses a debug binding when it is issued and again when it is used, so it works only against staging, test or development servers. It lives in the opt-in product **`LensJourneyDebugAttestation`**, not in the core `LensJourney` product (0.4.0). The core product has no unsigned proof: no `.debug` case, no `DebugAttestationProvider`, and no public way to build one, so an app target that does not link the debug product cannot send a debug attestation at all, whatever its build configuration. (An earlier approach compiled the type only under `#if DEBUG`, but a package cannot control how its consumers are configured: a staging TestFlight build is a Release build.)

How it is enforced. `AttestationPayload` has `.appAttest`, `.playIntegrity` and `.restricted(RestrictedAttestation)`. A `RestrictedAttestation` has no public initializer and no public fields: they use the `package` access level (Swift 5.9), so only targets of this package can create or read one, and `LensJourneyDebugAttestation` is the only target that does. The compiler refuses `RestrictedAttestation(...)` in an app that depends on the package. As a second line of defence the transport sends a restricted proof only if it was created in a source file of the `LensJourneyDebugAttestation` module (`#fileID`) and otherwise throws `.attestationFailed` with code `ATTESTATION_PAYLOAD_NOT_ALLOWED` before anything reaches `install-token`. `scripts/check-debug-attestation-boundary.sh` proves the rest: the core Release object has no `DebugAttestationProvider`; an app outside the package cannot compile `.debug(challenge:)`, `DebugAttestationProvider()`, `RestrictedAttestation(...)` or a read of one; an app that links the debug product builds and runs in Debug and Release; and for an Xcode-project iOS app (xcodebuild, iOS Simulator) a production target linking only `LensJourney` builds with no `DebugAttestationProvider` in its Release binary (and cannot compile a reference to it), while a staging target linking `LensJourneyDebugAttestation` builds in Debug and Release and its Release binary contains it.

Use it for simulator runs, CI and staging builds against a staging server:

```swift
// Package.swift or Xcode: link the product into the debug/staging target ONLY, never the production target.
.product(name: "LensJourneyDebugAttestation", package: "lens-journey-ios")

import LensJourneyDebugAttestation
let provider: AttestationProvider = DebugAttestationProvider()   // staging server only
```

**Migrating from 0.3.0 (source-incompatible).** In 0.3.0 `AttestationPayload` had `.debug(challenge:)` and `DebugAttestationProvider` was in the core product. In 0.4.0: (1) `.debug(challenge:)` is gone, so a custom provider that returned it must use `DebugAttestationProvider` from the new product instead (or be removed); (2) `AttestationPayload` has a new case `.restricted`, so an exhaustive `switch` over it needs that case; (3) staging, simulator and TestFlight-staging targets add the `LensJourneyDebugAttestation` product and `import LensJourneyDebugAttestation`; production targets do not link it and must not name `DebugAttestationProvider`. A production release gate that scans the binary for `DebugAttestationProvider` then passes because the symbol is only in the targets that opted in.

**Your own provider.** Implement `AttestationProvider.attest(challenge:installId:) async throws -> AttestationPayload`. The optional `attestationAccepted(installId:)`, `attestationRejected(installId:)` and `installIdReplaced(_:)` let a provider commit or drop state around the server's verdict: drop what you staged for a refused attempt, keep what the server already accepted, and drop everything for the old id when the SDK starts a new install.

Attestation failures are typed: `LensJourneyError.Kind.attestationFailed` (code `ATTESTATION_FAILED`, from the provider or from a server `401`), `.mobileChannelDisabled` (`403 MOBILE_CHANNEL_DISABLED`) and `.invalidConfiguration` (`SECRET_KEY_IN_APP`, `INVALID_MOBILE_KEY`). The mint calls themselves are not retried; a `429` is `.rateLimited`. A device that fails attestation cannot start a journey: emulators and rooted devices are refused by design.

Render every returned violation and prescription error. Treat a degraded gate as provisional. `finish()` is authoritative for price and eligibility; never invent a price from an error. The SDK retries 429 and 503 once, and reuses the same configuration idempotency key for that retry. The key also survives a `finish()` that failed (a surfaced 503 or a network error): calling `finish()` again with the same selections and prescription sends the same key, so the server does not create a second configuration. `start`, `select`, `back` and `setPrescription` start a new key.

`back()` is local (no request) and undoes the last `select`. With nothing to undo (before `start`, right after `start`, or once every pick is undone) it throws `LensJourneyError.Kind.invalidRequest`. Changing the prescription does not add an undo step; after `back()` the returned state's prescription check reflects the current prescription, but the earlier step's options, `enabled` flags and gate are as they were when that step was evaluated. This is display only: `back()` makes no request by design (its signature is synchronous and non-throwing on the network), and the server re-evaluates on the next `select`, so a stale option can be shown but never accepted. A 400 with code `INVALID_CLIENT_ID` is `LensJourneyError.Kind.invalidClientId`.

Stateful calls are exclusive: a second `start`, `select`, `back`, `setPrescription`, or `finish` while one is awaiting the network fails with `LensJourneyError.Kind.busy`. Selections must identify an enabled option in the current step; single-choice selections replace the node's prior value, while multiple-choice selections append without duplicates. Failed evaluations leave state unchanged. `finish()` requires a summary terminal.

For 429 responses, `Retry-After` accepts delta-seconds or an HTTP date and is clamped to 0–30 seconds; invalid, negative, or overflowing values fall back to one second. Tests can inject `sleep` and `clock` through the initializer. Starting again clears picks/history; a prescription set before `start` or for the same category is retained, while changing category clears it.

## Errors (same mapping on Android)

Every `LensJourneyError` carries a `kind`. Errors the SDK raises itself (validation, state, lock, transport, decode) also carry a `code`; errors mapped from an HTTP response carry the server's own `code`, which is `nil` when the server sent none. The mapping is the same on iOS and Android:

| Situation | iOS `kind` (code) | Android exception (code) |
| --- | --- | --- |
| Any status not listed in the HTTP mapping, including an unlisted 4xx such as 418 (also 500, 502, 504); not retried | `.unavailable` (server code; no status property) | `ServiceUnavailableException` (server code, real `status`) |
| `finish()` before `start`, with no picks, or before the journey reaches a summary | `.journeyIncomplete` (`JOURNEY_INCOMPLETE`) | `JourneyIncompleteException` (`JOURNEY_INCOMPLETE`) |
| `select()` with no current step, or a call that needs `start` first | `.invalidState` (`INVALID_STATE`) | `InvalidStateException` (`INVALID_STATE`) |
| A 2xx whose body cannot be decoded (evaluate, finish, scan) | `.malformedResponse` (`MALFORMED_RESPONSE`) | `MalformedResponseException` (`MALFORMED_RESPONSE`) |
| Client-side validation (lengths, limits) | `.invalidRequest` (`INVALID_REQUEST`) | `InvalidRequestException` (`INVALID_REQUEST`) |
| Transport failure | `.network` (`NETWORK_ERROR`) | `NetworkException` (`NETWORK_ERROR`) |
| A secret `cs_` key, or a key that is not `cspk_` | `.invalidConfiguration` (`SECRET_KEY_IN_APP`, `INVALID_MOBILE_KEY`) | `InvalidConfigurationException` (same codes) |
| The provider cannot attest, or the server refuses the attestation (`401`) | `.attestationFailed` (`ATTESTATION_FAILED`, `ATTESTATION_UNAVAILABLE`) | `AttestationException` (same codes) |
| `403 MOBILE_CHANNEL_DISABLED` on a mint | `.mobileChannelDisabled` | `MobileChannelDisabledException` |

A malformed 2xx commits nothing: the journey state, picks and history are as they were, and the operation lock is released. `scanPrescription` takes the same exclusive lock as the other stateful calls, so it fails with `.busy` while another call is in flight (and the other calls fail with `.busy` while a scan is).

## Price and brand

`finish()` returns a `LensConfiguration`. The server sends `subtotal` as a JSON **string** at the currency's decimals, such as `"120.00"` or `"22.345"` for KWD. The SDK reads it into an exact `Decimal`, never a `Double`. A JSON number is also accepted, but Foundation hands it over as a `Double`, so it loses precision above about 15 significant digits and drops trailing zeros (`1.50` reads as `1.5`, and `subtotalString` is `"1.5"`). A number that `Decimal` cannot hold (`1e308`) or whose text is longer than 40 characters (`1e127`) is a malformed response, as is a string longer than 40 characters or one that is not a plain decimal (no exponent, no surrounding whitespace, no trailing newline). **iOS and Android differ on numbers:** Android reads the number's own token text exactly (`1.50` stays `1.50`) but refuses any exponent form (`1e3`), which iOS cannot see because `Double` has already absorbed it. The server only ever sends strings, so treat a numeric `subtotal` as a tolerance, not a contract. Use `subtotal` for arithmetic and `subtotalString` for the exact text the server wrote (trailing zeros kept).

**`currency_decimals` is authoritative.** Catalogue markets (for example KWD and EUR) also send `subtotal_minor`, `currency_decimals`, `price_basis` and `price_basis_note`, and no `subtotal_paise`. `currencyMinorUnitDigits` returns the server's `currency_decimals`, and falls back to the ISO 4217 table (KWD 3, JPY 0, EUR 2) only when it is absent, as for India. `subtotalMinorUnits` returns the server's `subtotal_minor` when present and otherwise derives it from `subtotal` (nil if the amount has more digits than the currency). India keeps `subtotal_paise` and sends none of the new fields; `subtotalPaise` is passed through unchanged. Format with the currency's decimals, not a fixed two places.

**`subtotal` is the lens only, not the frame, and it is a quote when `priceBasis == "quote"`** (`isQuote`): an indicative price. The merchant's cart re-prices every line and is the charging authority, and this configuration is never charged. `priceBasisNote` carries the server's wording for the UI.

```swift
let done = try await journey.finish()
print(done.subtotalString ?? "-", done.currency ?? "", done.isQuote ? "(quote)" : "")   // "22.345 KWD (quote)"
```

A 2xx body that cannot be decoded (for example a `subtotal` that is neither a decimal string nor a number, or a `currency_decimals` that is not an integer from 0 to 6) throws `LensJourneyError.Kind.malformedResponse` (code `MALFORMED_RESPONSE`), not a raw `DecodingError`. This applies to `/evaluate`, `/rx-ocr` and `/configurations` responses.

`JourneyConfig(brand:)` is optional and takes a brand code the server knows (for example `"ACME"`). It must match the server's rule, a letter followed by up to 31 letters or digits after trimming (the server compares case-insensitively); anything else throws `.invalidRequest` from the initializer, and the trimmed value is what is sent. When set, the SDK sends `brand` on every `/evaluate` call and on the `/configurations` call made by `finish()`, so the server picks that brand's workflow. When nil it sends no `brand` field and behaviour is unchanged.

`LensJourney.version` is the SDK version (`"0.4.0"`).

## Distribution

Add the package by URL and pin an exact version while the API is `0.x`; commit Xcode's `Package.resolved`:

```swift
.package(url: "https://github.com/Answerable/lens-journey-ios.git", exact: "0.4.0")
```

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## Environments

`MobileKeyConfig.baseURL` selects the VARAi environment, and the mobile key must belong to that same environment, or every mint returns 401. There is no default base URL: pass the one for your environment. `currency` and `store` in `JourneyConfig` must match the tenant (for example a merchant selling in Kuwaiti dinar uses `currency: "KWD"`), the SDK does not check them. The SDK has no environment switch of its own.

## Handing the result to the merchant's cart

`finish()` returns a `LensConfiguration`. Its `id` is the configuration id; the session is `JourneyConfig.sessionId`. The app passes **only those two ids** (plus the frame and quantity) to the merchant's cart, and never a price: `subtotal` is an indicative quote for display, and the merchant's platform prices the line from its own catalogue (ADR-369). The platform reserves the configuration with VARAi, so a configuration cannot be used by two carts or by another shopper's session.

### Magento

Once the merchant's Magento store runs the `CommerceStudio/LensJourney` module that adds the lens cart (it ships separately from this SDK and is not in every store yet; the endpoints exist only with it, behind the store setting `commerce_studio_lens_journey/general/lens_cart_reserve_enabled`, off by default), it exposes:

- `POST /rest/V1/commerce-studio/lens-journey/cart` with the shopper's customer token (resource `self`).
- `POST /rest/V1/commerce-studio/lens-journey/guest-carts/{cartId}/items` for a guest, with the masked cart id.

```swift
struct LensCartLine: Encodable { let sku: String; let qty: Int; let configuration_id: String; let session_id: String }

var request = URLRequest(url: merchantBase.appendingPathComponent("rest/V1/commerce-studio/lens-journey/cart"))
request.httpMethod = "POST"
request.setValue("application/json", forHTTPHeaderField: "Content-Type")
request.setValue("Bearer \(customerToken)", forHTTPHeaderField: "Authorization")
request.httpBody = try JSONEncoder().encode(LensCartLine(sku: "FRAME-1", qty: 1, configuration_id: final.id, session_id: sessionId))
```

The body is `{ "sku" | "product_id": ..., "qty": ..., "configuration_id": ..., "session_id": ... }`. Any price in the body is ignored. Magento reserves the configuration, prices the frame and the lens products from its own catalogue and adds the line; if the reservation or the pricing fails, nothing is added and the shopper gets an error. When the order is placed, Magento confirms the configuration and carries the lens details onto the order.

## Compatibility: the proxy transport (deprecated)

> **Deprecated.** The 0.2 model, where the app talks only to a merchant-run proxy that holds a secret key, still works but is deprecated. Prefer the mobile key. A proxy must be a server you run; the secret key must never reach the app.

`URLSessionTransport` with your own proxy URL and header provider keeps working unchanged:

```swift
// URLSessionTransport throws for a non-https base URL (pass allowInsecureHTTP: true only in a debug build, e.g. http://localhost).
let transport = try URLSessionTransport(baseURL: URL(string: "https://shop.example.com/lens-proxy/")!) {
    ["Authorization": "Bearer \(await appSession.token)"]
}
let journey = LensJourney(config: try JourneyConfig(clientId: stableInstallID), transport: transport)
```

## Prescription capture

Camera and picker UI belong to the app. Pass captured bytes through `ImageIOPreparer`, show the returned draft in editable fields, and call `setPrescription` only after the shopper confirms it. An OCR draft never changes journey routing by itself.

```swift
// AVCapturePhotoOutput delegate:
let draft = try await journey.scanPrescription(photo: photo.fileDataRepresentation()!, preparer: ImageIOPreparer())

// A PHPickerViewController result can load Data, then use the same call:
result.itemProvider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
    // Move to an async Task, scan, display, edit, then confirm with setPrescription.
}
```

The default preparer validates image input, downsizes the long edge to 2048 px, and emits a JPEG below 4 MB. The SDK rejects uploads above 10 MB. Tests replay the shared recorded fixtures (`fixtures/`); they make no network calls.
