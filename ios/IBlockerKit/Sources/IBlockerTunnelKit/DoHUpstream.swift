import Foundation
import IBlockerKit

/// DNS-over-HTTPS upstream (RFC 8484 POST).
///
/// The default upstream. HTTP/2/3 multiplexing gives per-query concurrency
/// for free and, because the exchange is TCP-based on our side, upstream
/// truncation never happens.
///
/// IMPORTANT: inside the packet tunnel, the endpoint URL must use an IP
/// literal (https://1.1.1.1/dns-query). A hostname would be resolved through
/// the system resolver — which points at the tunnel itself.
public final class DoHUpstream: DNSUpstream, @unchecked Sendable {
    private let url: URL
    private static let log = Log(category: "upstream")
    private let configuration: URLSessionConfiguration
    private let makeSession: @Sendable (URLSessionConfiguration) -> URLSession
    private let lock = NSLock()
    private var _session: URLSession

    /// The session new queries use. Replaced by `resetConnection`.
    var session: URLSession { lock.withLock { _session } }

    public convenience init(url: URL, timeout: TimeInterval = 4) {
        self.init(url: url, timeout: timeout, sessionFactory: { URLSession(configuration: $0) })
    }

    init(url: URL, timeout: TimeInterval = 4,
         sessionFactory: @escaping @Sendable (URLSessionConfiguration) -> URLSession) {
        self.url = url
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.httpAdditionalHeaders = [
            "Accept": "application/dns-message",
            "Content-Type": "application/dns-message",
        ]
        self.configuration = configuration
        self.makeSession = sessionFactory
        self._session = sessionFactory(configuration)
    }

    /// Replaces the session so the next query opens a new connection; the old session's
    /// in-flight requests are cancelled.
    public func resetConnection(reason: String) {
        let fresh = makeSession(configuration)
        let old: URLSession = lock.withLock {
            let old = _session
            _session = fresh
            return old
        }
        old.invalidateAndCancel()
        Self.log.info("doh session replaced (\(url.absoluteString))")
    }

    public convenience init?(config: UpstreamConfig) {
        guard config.kind == .doh, let raw = config.dohURL, let url = URL(string: raw) else {
            return nil
        }
        self.init(url: url)
    }

    public func resolve(_ query: Data) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = query
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count >= 12 else {
            throw UpstreamError.badResponse
        }
        return data
    }
}
