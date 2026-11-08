import Network
import XCTest
@testable import LensJourney

final class URLSessionTransportTests: XCTestCase {
    func testRefusesANonHTTPSBaseURLUnlessInsecureHTTPIsExplicitlyAllowed() throws {
        for raw in ["http://shop.example.com/lens-proxy", "HTTP://shop.example.com", "ftp://shop.example.com", "shop.example.com/lens-proxy", "file:///tmp/proxy"] {
            XCTAssertThrowsError(try URLSessionTransport(baseURL: try XCTUnwrap(URL(string: raw))), raw) { error in
                let journeyError = error as? LensJourneyError
                XCTAssertEqual(journeyError?.kind, .invalidRequest, raw)
                XCTAssertEqual(journeyError?.code, "INSECURE_BASE_URL", raw)
            }
        }
        _ = try URLSessionTransport(baseURL: try XCTUnwrap(URL(string: "https://shop.example.com/lens-proxy")))
        _ = try URLSessionTransport(baseURL: try XCTUnwrap(URL(string: "HTTPS://shop.example.com")))
        // The README call shape: trailing header closure after the defaulted allowInsecureHTTP parameter.
        _ = try URLSessionTransport(baseURL: try XCTUnwrap(URL(string: "https://shop.example.com/lens-proxy/"))) { ["Authorization": "Bearer token"] }
        _ = try URLSessionTransport(baseURL: try XCTUnwrap(URL(string: "http://localhost:3000")), allowInsecureHTTP: true)
        XCTAssertThrowsError(try URLSessionTransport(baseURL: try XCTUnwrap(URL(string: "ftp://shop.example.com")), allowInsecureHTTP: true))
    }

    /// Redirects are never followed: a followed https-to-http hop would send the shopper's prescription and the app credential in clear.
    func testARedirectIsRefusedAtTheDelegate() async throws {
        let transport = try URLSessionTransport(baseURL: try XCTUnwrap(URL(string: "https://shop.example.com")))
        let from = try XCTUnwrap(URL(string: "https://shop.example.com/a")), to = try XCTUnwrap(URL(string: "http://shop.example.com/b"))
        let redirect = try XCTUnwrap(HTTPURLResponse(url: from, statusCode: 302, httpVersion: nil, headerFields: ["Location": to.absoluteString]))
        let task = URLSession.shared.dataTask(with: from)
        let followed = await transport.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: redirect, newRequest: URLRequest(url: to))
        XCTAssertNil(followed)
    }

    /// The same refusal on the wire, against a real server: the 302 comes back as a status and the Location is never requested.
    /// (Plain http because a TLS test server is not available; the https-to-http hop is covered by the delegate test above.)
    func testARedirectIsReturnedAsAStatusAndNeverFollowedOnTheWire() async throws {
        let target = try LoopbackServer { _ in "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok" }
        defer { target.stop() }
        let targetPort = try await startOrSkip(target)
        let origin = try LoopbackServer { _ in "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(targetPort)/stolen\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" }
        defer { origin.stop() }
        let originPort = try await startOrSkip(origin)

        let transport = try URLSessionTransport(baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:\(originPort)")), allowInsecureHTTP: true)
        let response = try await transport.send(TransportRequest(method: "POST", path: "/api/v1/lens-journey/evaluate", headers: ["Authorization": "Bearer secret"], body: Data("{}".utf8), contentType: "application/json"))
        XCTAssertEqual(response.status, 302, "the redirect response is returned as is")
        XCTAssertEqual(origin.hits, 1)
        XCTAssertEqual(target.hits, 0, "the redirect target must never be contacted")
    }

    private func startOrSkip(_ server: LoopbackServer) async throws -> UInt16 {
        do { return try await server.start() }
        catch { throw XCTSkip("Skipped, not passed: the test listener on 127.0.0.1 could not start (\(error)).") }
    }
}

/// A one-shot-per-connection HTTP server that counts the requests it receives. Tests only ever connect to it on 127.0.0.1.
/// It does not set `requiredInterfaceType = .loopback`: that restriction is not proven on hosted macOS runners, so it is left out.
private final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackServer")
    private let lock = NSLock()
    private var count = 0
    private var finished = false
    private let respond: @Sendable (String) -> String

    init(respond: @escaping @Sendable (String) -> String) throws {
        self.respond = respond
        listener = try NWListener(using: .tcp, on: .any)
    }

    var hits: Int { lock.lock(); defer { lock.unlock() }; return count }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                self.lock.lock(); self.count += 1; self.lock.unlock()
                let head = String(decoding: data ?? Data(), as: UTF8.self)
                connection.send(content: Data(self.respond(head).utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            // Resume exactly once: the first terminal state wins (ready, failed, or cancelled before ready).
            func finish(_ result: Result<UInt16, Error>) {
                lock.lock(); let already = finished; finished = true; lock.unlock()
                if !already { continuation.resume(with: result) }
            }
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue { finish(.success(port)) } else { finish(.failure(URLError(.cannotConnectToHost))) }
                case .failed(let error): finish(.failure(error))
                case .cancelled: finish(.failure(URLError(.cancelled)))
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }
}
