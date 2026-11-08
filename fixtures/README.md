# Shared fixtures for the lens journey SDKs

Both SDKs (`android`, `ios`) decode and replay these files in their tests, so they cannot drift apart. Every file records a request and the response the server gave. Names, ids, SKUs, prices and hosts are neutral example values (no real tenant, customer or environment appears in them).

- `evaluate-*.json`, `configurations-real-response.json`: captured from a live test environment on 2026-10-28 with a throwaway tenant (deleted) and a single-vision workflow. Each file holds the request and the response (status, selected headers, body).
- `rx-ocr-*-captured.json`: captured from the real server code (2026-11-05), with only the model call, the database insert and the storage write stubbed. The response shape, string values and the `confidence` token (`"high"` / `"low"`) are the server's.
- `configurations-201-captured.json`: captured from the real server code and a real Postgres (throwaway India-market tenant, price-book row). `subtotal` is the decimal string `"45000.00"`.
- `configurations-201-kwd-captured.json`, `configurations-201-eur-captured.json`: captured from the real server code, locally (2026-11-03), with only the merchant's store faked at the HTTP boundary. Each holds the POST request and response and a `follow_up_get` (the GET that follows), for a catalogue-market tenant (KWD: three decimals, `subtotal_minor` in fils; EUR: two decimals). These markets send `subtotal_minor`, `currency_decimals`, `price_basis`, `price_basis_note` and no `subtotal_paise`; `currency_decimals` is authoritative.
- Hand-made "derived" fixtures are not used: they used a numeric `confidence` and a numeric `subtotal`, which the server never sends, so SDK models passed their tests and failed on the real response. Add a new fixture only by capturing it, then replace identifying values with neutral ones.
- No file contains a key, token or secret.
