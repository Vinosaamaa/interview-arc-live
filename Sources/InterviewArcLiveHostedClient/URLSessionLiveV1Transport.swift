import Foundation

public final class URLSessionLiveV1Transport: LiveV1Transport,
    @unchecked Sendable {
    public static let productionOrigin = URL(
        string: "https://limitless-mcp.vinosama.workers.dev"
    )!

    private let origin: URL
    private let redirectDelegate: LiveSameOriginRedirectDelegate
    private let session: URLSession

    public init(origin: URL = productionOrigin) throws {
        guard let scheme = origin.scheme?.lowercased(),
              origin.host != nil,
              origin.path.isEmpty || origin.path == "/",
              origin.query == nil,
              origin.fragment == nil,
              scheme == "https" || Self.isLoopback(origin) else {
            throw LiveV1ClientError.invalidConfiguration
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = true
        let redirectDelegate = LiveSameOriginRedirectDelegate(origin: origin)
        self.origin = origin
        self.redirectDelegate = redirectDelegate
        session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }

    deinit { session.invalidateAndCancel() }

    public func send(_ request: LiveV1Request) async throws -> LiveV1HTTPResponse {
        guard request.path.hasPrefix("/live/v1/"),
              var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
            throw LiveV1ClientError.invalidConfiguration
        }
        components.path = request.path
        guard let url = components.url else {
            throw LiveV1ClientError.invalidConfiguration
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: urlRequest)
        guard let response = response as? HTTPURLResponse else {
            throw LiveV1ClientError.malformedResponse
        }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        return LiveV1HTTPResponse(
            statusCode: response.statusCode,
            headers: headers,
            body: data
        )
    }

    private static func isLoopback(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http" else { return false }
        return switch url.host?.lowercased() {
        case "localhost", "127.0.0.1", "::1": true
        default: false
        }
    }
}

private final class LiveSameOriginRedirectDelegate: NSObject,
    URLSessionTaskDelegate, @unchecked Sendable {
    private let origin: URL

    init(origin: URL) { self.origin = origin }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let destination = request.url,
              Self.sameOrigin(origin, destination) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && lhs.port == rhs.port
    }

}
