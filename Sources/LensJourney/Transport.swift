import Foundation

public struct TransportRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data?
    public let contentType: String?

    public init(method: String, path: String, headers: [String: String] = [:], body: Data? = nil, contentType: String? = nil) {
        self.method = method; self.path = path; self.headers = headers; self.body = body; self.contentType = contentType
    }
}

public struct TransportResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    public init(status: Int, headers: [String: String] = [:], body: Data) { self.status = status; self.headers = headers; self.body = body }
}

public protocol Transport: Sendable {
    func send(_ request: TransportRequest) async throws -> TransportResponse
}

public final class URLSessionTransport: NSObject, Transport, URLSessionTaskDelegate, @unchecked Sendable {
    public typealias HeaderProvider = @Sendable () async throws -> [String: String]
    private let baseURL: URL
    private let headerProvider: HeaderProvider
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// The base URL must be https: the app talks to the merchant's proxy and carries shopper prescriptions and the app credential.
    /// `allowInsecureHTTP` is a debug opt-in (a simulator reaching http://localhost) and must never be set in a release build.
    public init(baseURL: URL, allowInsecureHTTP: Bool = false, headerProvider: @escaping HeaderProvider = { [:] }) throws {
        let scheme = baseURL.scheme?.lowercased()
        guard scheme == "https" || (allowInsecureHTTP && scheme == "http") else {
            throw LensJourneyError(kind: .invalidRequest, code: "INSECURE_BASE_URL", message: allowInsecureHTTP ? "baseURL must use http or https" : "baseURL must use https (allowInsecureHTTP is for local debugging only)")
        }
        self.baseURL = baseURL; self.headerProvider = headerProvider
    }

    public func send(_ request: TransportRequest) async throws -> TransportResponse {
        guard let url = URL(string: request.path, relativeTo: baseURL)?.absoluteURL else { throw URLError(.badURL) }
        var urlRequest = URLRequest(url: url, timeoutInterval: 15)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        var headers = try await headerProvider()
        request.headers.forEach { headers[$0.key] = $0.value }
        if let contentType = request.contentType { headers["Content-Type"] = contentType }
        headers.forEach { urlRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (bytes, response) = try await session.bytes(for: urlRequest)
        var data = Data(); data.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            guard data.count < 10 * 1024 * 1024 else {
                bytes.task.cancel()
                throw LensJourneyError(kind: .payloadTooLarge, code: "RESPONSE_TOO_LARGE", message: "Response exceeded 10 MB")
            }
            data.append(byte)
        }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let responseHeaders = http.allHeaderFields.reduce(into: [String: String]()) { result, item in
            result[String(describing: item.key)] = String(describing: item.value)
        }
        return TransportResponse(status: http.statusCode, headers: responseHeaders, body: data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
}
