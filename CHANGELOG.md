# Changelog

All notable changes to the Lens Journey Swift SDK. Versions are `0.x`: the API can change in a minor release (see the README).

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
- CI runs `swift test` in debug and release on two pinned Xcode toolchains.

## 0.1.0

- First pre-release.
