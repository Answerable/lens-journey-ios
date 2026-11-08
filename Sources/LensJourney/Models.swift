import Foundation

public enum JSONScalar: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else { throw DecodingError.typeMismatch(JSONScalar.self, .init(codingPath: decoder.codingPath, debugDescription: "Expected scalar JSON value")) }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self { case .string(let v): try value.encode(v); case .number(let v): try value.encode(v); case .bool(let v): try value.encode(v); case .null: try value.encodeNil() }
    }
}

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), scalar(JSONScalar)
    public init(from decoder: Decoder) throws {
        if let object = try? decoder.singleValueContainer().decode([String: JSONValue].self) { self = .object(object) }
        else if let array = try? decoder.singleValueContainer().decode([JSONValue].self) { self = .array(array) }
        else { self = .scalar(try JSONScalar(from: decoder)) }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self { case .object(let v): try value.encode(v); case .array(let v): try value.encode(v); case .scalar(let v): try value.encode(v) }
    }
    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
}

public protocol UnknownStringEnum: Codable, RawRepresentable where RawValue == String { static var unknown: Self { get } }
public extension UnknownStringEnum {
    init(from decoder: Decoder) throws { self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

public enum Terminal: String, UnknownStringEnum, Sendable { case choice, summary, block, deadEnd = "dead-end", maxSteps = "max-steps", unknown }
public enum StepType: String, UnknownStringEnum, Sendable { case choice, summary, block, unknown }
public enum SelectionMode: String, UnknownStringEnum, Sendable { case single, multiple, unknown }
public enum GateDecision: String, UnknownStringEnum, Sendable { case pass, fail, unknown }
public enum VisionType: String, Codable, Sendable { case distance, near }

public struct FrameRef: Codable, Equatable, Sendable {
    public let sku: String?; public let productId: String?
    public init(sku: String? = nil, productId: String? = nil) { self.sku = sku; self.productId = productId }
    enum CodingKeys: String, CodingKey { case sku; case productId = "product_id" }
}

public struct JourneyConfig: Equatable, Sendable {
    public let sessionId: String; public let clientId: String; public let currency: String?; public let store: String?
    /// Optional lens brand (for example "ACME") the server uses to pick the brand's workflow. Must match the server's rule, a letter then up to
    /// 31 letters or digits after trimming (anything else throws `.invalidRequest` here). The trimmed value is what is sent, on `/evaluate` and on
    /// `finish()`'s `/configurations` call, and only when set; nil keeps the server's default workflow selection.
    public let brand: String?
    /// `brand` trimmed, as sent to the server.
    var wireBrand: String? { brand?.trimmingCharacters(in: .whitespacesAndNewlines) }
    public init(sessionId: String = UUID().uuidString, clientId: String = UUID().uuidString.replacingOccurrences(of: "-", with: "_"), currency: String? = nil, store: String? = nil, brand: String? = nil) throws {
        guard clientId.range(of: "^[A-Za-z0-9_-]{8,64}$", options: .regularExpression) != nil else { throw LensJourneyError(kind: .invalidClientId, code: "INVALID_CLIENT_ID", message: "clientId must be 8 to 64 URL-safe characters") }
        guard !sessionId.isEmpty, sessionId.count <= 200 else { throw LensJourneyError(kind: .invalidRequest, code: "INVALID_REQUEST", message: "sessionId must be 1 to 200 characters") }
        if let brand {
            // The server's rule: trimmed, then ^[A-Za-z][A-Za-z0-9]{0,31}$ (matched case-insensitively there). The trimmed value is what is sent.
            let trimmed = brand.trimmingCharacters(in: .whitespacesAndNewlines)
            let scalars = Array(trimmed.unicodeScalars)
            func ascii(_ s: Unicode.Scalar, digits: Bool) -> Bool { (s.value >= 65 && s.value <= 90) || (s.value >= 97 && s.value <= 122) || (digits && s.value >= 48 && s.value <= 57) }
            guard (1...32).contains(scalars.count), ascii(scalars[0], digits: false), scalars.dropFirst().allSatisfy({ ascii($0, digits: true) }) else {
                throw LensJourneyError(kind: .invalidRequest, code: "INVALID_REQUEST", message: "brand must be a letter followed by up to 31 letters or digits")
            }
        }
        self.sessionId = sessionId; self.clientId = clientId; self.currency = currency; self.store = store; self.brand = brand
    }
}

public struct JourneyState: Codable, Equatable, Sendable {
    public let workflowVersion: String?; public let category: String; public let terminal: Terminal; public let step: Step?
    public let selections: [String: [Selection]]; public let autoSelected: [JSONValue]; public let violations: [Violation]
    public let prescription: PrescriptionCheck?; public let settingsWarnings: [JSONValue]; public let gate: Gate?
    enum CodingKeys: String, CodingKey { case workflowVersion = "workflow_version", category, terminal, step, selections; case autoSelected = "auto_selected"; case violations, prescription; case settingsWarnings = "settings_warnings"; case gate }
}
public struct Selection: Codable, Equatable, Sendable {
    public let optionId: String; public let optionLabel: String?
    public init(optionId: String, optionLabel: String? = nil) { self.optionId = optionId; self.optionLabel = optionLabel }
    enum CodingKeys: String, CodingKey { case optionId, optionLabel }
    public init(from decoder: Decoder) throws {
        if let string = try? decoder.singleValueContainer().decode(String.self) { self.init(optionId: string); return }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(optionId: try values.decode(String.self, forKey: .optionId), optionLabel: try values.decodeIfPresent(String.self, forKey: .optionLabel))
    }
}
public struct Step: Codable, Equatable, Sendable {
    public let id: String; public let type: StepType; public let label: String; public let selectionMode: SelectionMode; public let options: [Option]
    enum CodingKeys: String, CodingKey { case id, type, label; case selectionMode = "selection_mode"; case options }
}
public struct Option: Codable, Equatable, Sendable {
    public let id: String; public let label: String; public let price: Double?; public let msrp: Double?; public let platformSku: String?
    public let addonSkus: [String]?; public let enabled: Bool; public let recommended: Bool; public let metadata: [String: JSONScalar]?
    enum CodingKeys: String, CodingKey { case id, label, price, msrp; case platformSku = "platform_sku"; case addonSkus = "addon_skus"; case enabled, recommended, metadata }
}
public struct Violation: Codable, Equatable, Sendable { public let code: String; public let nodeId: String? }
public struct PrescriptionError: Codable, Equatable, Sendable { public let field: String; public let code: String }
public struct NumericRange: Codable, Equatable, Sendable { public let min: Double; public let max: Double; public let step: Double? }
public struct PDRange: Codable, Equatable, Sendable { public let binocular: NumericRange; public let monocular: NumericRange }
public struct PrescriptionRanges: Codable, Equatable, Sendable { public let sph: NumericRange?; public let cyl: NumericRange?; public let add: NumericRange?; public let pd: PDRange?; public let axis: NumericRange? }
public struct PrescriptionCheck: Codable, Equatable, Sendable { public let complete: Bool; public let errors: [PrescriptionError]; public let normalized: Prescription?; public let ranges: PrescriptionRanges? }
public struct Gate: Codable, Equatable, Sendable { public let decision: GateDecision; public let degraded: Bool; public let reason: String? }

public struct EyePrescription: Codable, Equatable, Sendable {
    public var sph: JSONScalar?; public var cyl: JSONScalar?; public var axis: JSONScalar?; public var add: JSONScalar?
    public init(sph: JSONScalar? = nil, cyl: JSONScalar? = nil, axis: JSONScalar? = nil, add: JSONScalar? = nil) { self.sph = sph; self.cyl = cyl; self.axis = axis; self.add = add }
}
/// How sure the server's reader is of a photographed prescription. The server answers the string "high" (both spheres read)
/// or "low", never a number. Any other value, or a non-string, decodes to `.unknown` instead of failing the whole scan.
public enum OCRConfidence: String, Codable, Equatable, Sendable {
    case high, low, unknown
    public init(from decoder: Decoder) throws {
        let value = try? decoder.singleValueContainer().decode(String.self)
        self = value.flatMap(OCRConfidence.init(rawValue:)) ?? .unknown
    }
}

public struct Prescription: Codable, Equatable, Sendable {
    public var od: EyePrescription; public var os: EyePrescription; public var pd: JSONScalar?; public var pdOd: JSONScalar?; public var pdOs: JSONScalar?; public var confidence: OCRConfidence?
    public init(od: EyePrescription, os: EyePrescription, pd: JSONScalar? = nil, pdOd: JSONScalar? = nil, pdOs: JSONScalar? = nil, confidence: OCRConfidence? = nil) { self.od = od; self.os = os; self.pd = pd; self.pdOd = pdOd; self.pdOs = pdOs; self.confidence = confidence }
    enum CodingKeys: String, CodingKey { case od, os, pd, pdOd, pdOs, confidence }
    /// `confidence` describes the photo, not the values, so it is sent back only when the server named it ("high" or "low").
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(od, forKey: .od); try values.encode(os, forKey: .os)
        try values.encodeIfPresent(pd, forKey: .pd); try values.encodeIfPresent(pdOd, forKey: .pdOd); try values.encodeIfPresent(pdOs, forKey: .pdOs)
        if let confidence, confidence != .unknown { try values.encode(confidence, forKey: .confidence) }
    }
}
public struct PrescriptionDraft: Codable, Equatable, Sendable { public let prescription: Prescription; public let confirmed: Bool; public init(prescription: Prescription) { self.prescription = prescription; self.confirmed = false } }
struct OCRResponse: Codable { let prescription: Prescription }

public struct LensConfiguration: Codable, Equatable, Sendable {
    public let id: String; public let lensSummary: JSONValue?
    /// The configuration subtotal as an exact decimal. The server sends it as a JSON string such as "120.00" or "12.345" (a number is also
    /// accepted); a string is never read through a `Double`, so a 3-decimal currency such as KWD keeps its precision.
    public let subtotal: Decimal?
    /// The subtotal exactly as the server wrote it ("120.00" keeps its trailing zeros, which `Decimal` cannot). For a numeric JSON value this is the
    /// number's shortest decimal text.
    public let subtotalString: String?
    /// The server's integer `subtotal_paise` field, passed through unchanged. Its name is historical; use `subtotalMinorUnits` for an amount scaled by `currency`.
    public let subtotalPaise: Int?; public let currency: String?
    /// Catalogue markets only: `subtotal` in the currency's minor units (22345 for "22.345" KWD). Authoritative when present. India sends none.
    public let subtotalMinor: Int64?
    /// Catalogue markets only: the currency's decimal places as the server applied them. Authoritative over the ISO table. India sends none.
    public let currencyDecimals: Int?
    /// Catalogue markets only: "quote" means `subtotal` is an indicative lens-only quote and the merchant cart is the charging authority.
    public let priceBasis: String?
    /// Catalogue markets only: the server's human-readable explanation of `priceBasis`.
    public let priceBasisNote: String?
    /// Only on the follow-up `GET /configurations/:id` body ("draft"); the POST 201 does not carry it.
    public let status: String?
    public let breakdown: [JSONValue]; public let inheritedFromPartner: Bool; public let prescriptionOnFile: Bool; public let photoAttached: Bool?; public let photoAttachError: String?; public let photos: [JSONValue]?
    enum CodingKeys: String, CodingKey { case id; case lensSummary = "lens_summary"; case subtotal; case subtotalPaise = "subtotal_paise"; case subtotalMinor = "subtotal_minor"; case currencyDecimals = "currency_decimals"; case priceBasis = "price_basis"; case priceBasisNote = "price_basis_note"; case status; case currency, breakdown; case inheritedFromPartner = "inherited_from_partner"; case prescriptionOnFile = "prescription_on_file"; case photoAttached = "photo_attached"; case photoAttachError = "photo_attach_error"; case photos }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        lensSummary = try values.decodeIfPresent(JSONValue.self, forKey: .lensSummary)
        let exact = try ExactDecimal.decodeIfPresent(from: values, forKey: .subtotal)
        subtotal = exact?.value; subtotalString = exact?.text
        subtotalPaise = try values.decodeIfPresent(Int.self, forKey: .subtotalPaise)
        subtotalMinor = try values.decodeIfPresent(Int64.self, forKey: .subtotalMinor)
        currencyDecimals = try values.decodeIfPresent(Int.self, forKey: .currencyDecimals)
        if let currencyDecimals, !(0...6).contains(currencyDecimals) { throw DecodingError.dataCorruptedError(forKey: .currencyDecimals, in: values, debugDescription: "currency_decimals must be 0 to 6") }
        priceBasis = try values.decodeIfPresent(String.self, forKey: .priceBasis)
        priceBasisNote = try values.decodeIfPresent(String.self, forKey: .priceBasisNote)
        status = try values.decodeIfPresent(String.self, forKey: .status)
        currency = try values.decodeIfPresent(String.self, forKey: .currency)
        breakdown = try values.decode([JSONValue].self, forKey: .breakdown)
        // Absent on the follow-up GET body, so they default rather than fail.
        inheritedFromPartner = try values.decodeIfPresent(Bool.self, forKey: .inheritedFromPartner) ?? false
        prescriptionOnFile = try values.decodeIfPresent(Bool.self, forKey: .prescriptionOnFile) ?? false
        photoAttached = try values.decodeIfPresent(Bool.self, forKey: .photoAttached)
        photoAttachError = try values.decodeIfPresent(String.self, forKey: .photoAttachError)
        photos = try values.decodeIfPresent([JSONValue].self, forKey: .photos)
    }

    /// Encodes `subtotal` back as the server's string shape, so decode -> encode -> decode is lossless.
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encodeIfPresent(lensSummary, forKey: .lensSummary)
        try values.encodeIfPresent(subtotalString, forKey: .subtotal); try values.encodeIfPresent(subtotalPaise, forKey: .subtotalPaise)
        try values.encodeIfPresent(subtotalMinor, forKey: .subtotalMinor); try values.encodeIfPresent(currencyDecimals, forKey: .currencyDecimals)
        try values.encodeIfPresent(priceBasis, forKey: .priceBasis); try values.encodeIfPresent(priceBasisNote, forKey: .priceBasisNote); try values.encodeIfPresent(status, forKey: .status)
        try values.encodeIfPresent(currency, forKey: .currency); try values.encode(breakdown, forKey: .breakdown)
        try values.encode(inheritedFromPartner, forKey: .inheritedFromPartner); try values.encode(prescriptionOnFile, forKey: .prescriptionOnFile)
        try values.encodeIfPresent(photoAttached, forKey: .photoAttached); try values.encodeIfPresent(photoAttachError, forKey: .photoAttachError)
        try values.encodeIfPresent(photos, forKey: .photos)
    }

    /// True when the server says `subtotal` is an indicative quote (`priceBasis == "quote"`): the merchant cart, not this configuration, charges.
    public var isQuote: Bool { priceBasis == "quote" }
    /// Minor-unit digits for `currency`. The server's `currency_decimals` is authoritative; only when it is absent (India) does this fall back to the
    /// ISO 4217 table (KWD 3, JPY 0, EUR 2) for `currency`. Nil when the response has neither.
    public var currencyMinorUnitDigits: Int? { currencyDecimals ?? currency.map { CurrencyMinorUnits.digits(for: $0) } }
    /// `subtotal` in the currency's minor units (22.345 KWD is 22345). The server's `subtotal_minor` wins when present; otherwise it is derived from
    /// `subtotal` and `currencyMinorUnitDigits`. Nil when neither is possible, or when the subtotal has more digits than the currency has.
    public var subtotalMinorUnits: Int64? {
        if let subtotalMinor { return subtotalMinor }
        guard let subtotal, let digits = currencyMinorUnitDigits else { return nil }
        var scaled = subtotal * pow(Decimal(10), digits)
        var whole = Decimal()
        NSDecimalRound(&whole, &scaled, 0, .plain)
        guard whole == scaled, abs(whole) < Decimal(1_000_000_000_000_000) else { return nil }
        return NSDecimalNumber(decimal: whole).int64Value
    }
}

enum CurrencyMinorUnits {
    private static let zero: Set<String> = ["BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG", "RWF", "UGX", "UYI", "VND", "VUV", "XAF", "XOF", "XPF"]
    private static let three: Set<String> = ["BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND"]
    private static let four: Set<String> = ["CLF", "UYW"]
    /// Keep this table identical to the Android SDK's `CurrencyMinorUnits`; both are tested against the same codes.
    static func digits(for code: String) -> Int {
        let upper = code.uppercased()
        if zero.contains(upper) { return 0 }
        if three.contains(upper) { return 3 }
        if four.contains(upper) { return 4 }
        return 2
    }
}

/// Reads a JSON decimal that arrives as a string or a number. A string is parsed from its text, never through a `Double`. Both forms end up as a
/// plain decimal of at most `maxLength` characters (Android applies the same bound to the token). A JSON NUMBER is different: Foundation hands
/// it over as a `Double`, so its text is the shortest round-trip form of that Double (1.50 reads as "1.5"), and a value `Decimal` cannot hold
/// (1e308) or whose text is longer than the bound (1e127) is refused. The server sends strings; see the README.
enum ExactDecimal {
    static let maxLength = 40
    private static let plain = try! NSRegularExpression(pattern: "\\A-?[0-9]+(\\.[0-9]+)?\\z")
    static func decodeIfPresent<K: CodingKey>(from values: KeyedDecodingContainer<K>, forKey key: K) throws -> (value: Decimal, text: String)? {
        guard values.contains(key), try !values.decodeNil(forKey: key) else { return nil }
        if let text = try? values.decode(String.self, forKey: key) {
            let range = NSRange(text.startIndex..., in: text)
            guard text.count <= maxLength, plain.firstMatch(in: text, range: range) != nil, let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else {
                throw DecodingError.dataCorruptedError(forKey: key, in: values, debugDescription: "Expected a plain decimal string such as \"120.00\" of at most \(maxLength) characters")
            }
            return (value, text)
        }
        if let number = try? values.decode(Double.self, forKey: key), number.isFinite {
            // A JSON number is read through Double (the server sends strings); Double's description is the shortest text that round-trips.
            guard let value = Decimal(string: "\(number)", locale: Locale(identifier: "en_US_POSIX")), !value.isNaN, "\(value)".count <= maxLength else {
                throw DecodingError.dataCorruptedError(forKey: key, in: values, debugDescription: "Expected a decimal number of at most \(maxLength) characters")
            }
            return (value, "\(value)")
        }
        throw DecodingError.typeMismatch(Decimal.self, .init(codingPath: values.codingPath + [key], debugDescription: "Expected a decimal string or number"))
    }
}

public struct LensJourneyError: Error, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case invalidClientId, invalidRequest, unauthorized, insufficientScope, workflowNotPublished, payloadTooLarge, unsupportedMediaType, unprocessable, rateLimited, unavailable, network, requestTooLarge, invalidState, invalidImage, busy, invalidSelection, journeyIncomplete, malformedResponse }
    public let kind: Kind; public let code: String?; public let message: String; public let details: JSONValue?; public let requestId: String?; public let documentationURL: String?
    public init(kind: Kind, code: String? = nil, message: String, details: JSONValue? = nil, requestId: String? = nil, documentationURL: String? = nil) { self.kind = kind; self.code = code; self.message = message; self.details = details; self.requestId = requestId; self.documentationURL = documentationURL }
}
