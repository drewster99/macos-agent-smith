import Foundation

/// A `URLProtocol` that returns a canned response (status + body, or a transport error) so the
/// network layer of the web tools can be tested deterministically — non-200 status, anti-bot
/// pages, malformed/non-UTF-8 bodies — without hitting the real network.
///
/// Usage: build a session with `URLProtocolStub.makeSession()`, call `setResponse(...)` before
/// the request, and `reset()` after. Because the canned response lives in lock-guarded static
/// state, suites that use it must be `.serialized`.
final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    private struct Canned {
        let statusCode: Int
        let body: Data
        let error: Error?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var canned: Canned?

    static func setResponse(statusCode: Int = 200, body: Data = Data(), error: Error? = nil) {
        lock.lock(); defer { lock.unlock() }
        canned = Canned(statusCode: statusCode, body: body, error: error)
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        canned = nil
    }

    private static func current() -> Canned? {
        lock.lock(); defer { lock.unlock() }
        return canned
    }

    /// A `URLSession` configured to route all requests through this stub.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let response = Self.current() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let url = request.url,
              let httpResponse = HTTPURLResponse(
                url: url, statusCode: response.statusCode, httpVersion: "HTTP/1.1", headerFields: nil
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotParseResponse))
            return
        }
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
