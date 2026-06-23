import Foundation

/// A `URLProtocol` that returns a canned response, isolated **per session** so concurrently
/// running test suites can't clobber one another's stub. Build a session with
/// `URLProtocolStub.makeSession(statusCode:body:error:)`; the canned response is keyed to that
/// session via a unique id header, so there is no shared "current response" global to race on.
///
/// Usage: `let session = URLProtocolStub.makeSession(statusCode: 200, body: data)` then inject
/// `session` into the code under test. No teardown needed.
final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    private struct Canned {
        let statusCode: Int
        let body: Data
        let error: Error?
        let headerFields: [String: String]?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var registry: [String: Canned] = [:]
    private static let idHeader = "X-URLProtocolStub-Id"

    /// A `URLSession` that returns the given canned response for every request, identified by a
    /// unique id carried in a header on the session's requests.
    static func makeSession(statusCode: Int = 200, body: Data = Data(), error: Error? = nil, headerFields: [String: String]? = nil) -> URLSession {
        let id = UUID().uuidString
        lock.lock()
        registry[id] = Canned(statusCode: statusCode, body: body, error: error, headerFields: headerFields)
        lock.unlock()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        config.httpAdditionalHeaders = [idHeader: id]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let canned: Canned? = {
            guard let id = request.value(forHTTPHeaderField: Self.idHeader) else { return nil }
            Self.lock.lock(); defer { Self.lock.unlock() }
            return Self.registry[id]
        }()
        guard let response = canned else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let url = request.url,
              let httpResponse = HTTPURLResponse(
                url: url, statusCode: response.statusCode, httpVersion: "HTTP/1.1", headerFields: response.headerFields
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
