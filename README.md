# LensJourney for Swift

> **Pre-release (0.x).** The API can still change without notice. Pin an exact version.

`LensJourney` is a Foundation-only Swift package for Commerce Studio's server-driven lens journey. It requires iOS 15 or macOS 12 and Swift 5.9. The SDK contains no API secret and no lens rules: the host supplies a `Transport`, or uses `URLSessionTransport` with its own authenticated proxy URL and header provider.

```swift
// URLSessionTransport throws for a non-https base URL (pass allowInsecureHTTP: true only in a debug build, e.g. http://localhost).
let transport = try URLSessionTransport(baseURL: URL(string: "https://shop.example.com/lens-proxy/")!) {
    ["Authorization": "Bearer \(await appSession.token)"]
}
let config = try JourneyConfig(clientId: stableInstallID, currency: "USD", store: "us")
let journey = LensJourney(config: config, transport: transport)
var state = try await journey.start(category: "single-vision", frame: FrameRef(sku: "FRAME-1"), vision: .distance)
state = try await journey.select(optionId: "anti-reflective")
let final = try await journey.finish() // final.id is the configuration the host carries to its cart
```

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

`LensJourney.version` is the SDK version (`"0.2.0"`).

## Distribution

Add the package by URL and pin an exact version while the API is `0.x`; commit Xcode's `Package.resolved`:

```swift
.package(url: "https://github.com/Answerable/lens-journey-ios.git", exact: "0.2.0")
```

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## Environments

The app only ever talks to the merchant's proxy (`baseURL` above). The proxy decides which VARAi environment it calls. The API key the proxy holds must belong to that same environment, or every call returns 401. `currency` and `store` in `JourneyConfig` must match the tenant (for example a merchant selling in Kuwaiti dinar uses `currency: "KWD"`), the SDK does not check them. The SDK has no environment switch of its own.

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
