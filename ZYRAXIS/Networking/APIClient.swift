import Foundation

/// Production-ready HTTP layer over URLSession.
///
/// Guarantees:
/// - configurable base URL + timeout (see `BackendConfig`)
/// - cooperative cancellation (throws `NetworkError.cancelled`)
/// - structured errors (see `NetworkError`), no raw URLErrors leak to callers
public protocol APIClient: Sendable {
    func sendData(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T
    func makeRequest(path: String, method: String, body: Data?, headers: [String: String]) throws -> URLRequest
}

public final class URLSessionAPIClient: APIClient, Sendable {

    private let session: URLSession
    private let config: BackendConfig

    public init(config: BackendConfig, session: URLSession? = nil) {
        self.config = config
        if let session {
            self.session = session
        } else {
            let sc = URLSessionConfiguration.ephemeral
            sc.timeoutIntervalForRequest = config.requestTimeout
            sc.timeoutIntervalForResource = config.requestTimeout * 2
            sc.waitsForConnectivity = true
            self.session = URLSession(configuration: sc)
        }
    }

    public func makeRequest(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        headers: [String: String] = [:]
    ) throws -> URLRequest {
        guard let base = config.baseURL else {
            throw NetworkError.transport("Backend not configured. Set the backend URL in Settings.")
        }
        guard let url = URL(string: path, relativeTo: base) else {
            throw NetworkError.invalidURL(path)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.timeoutInterval = config.requestTimeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        return req
    }

    public func sendData(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            try Task.checkCancellation()
        } catch {
            throw NetworkError.cancelled
        }
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw NetworkError.transport("Non-HTTP response.")
            }
            guard 200..<300 ~= http.statusCode else {
                let snippet = String(data: data.prefix(512), encoding: .utf8)
                throw NetworkError.fromStatusCode(http.statusCode, message: snippet)
            }
            return (data, http)
        } catch let e as NetworkError {
            throw e
        } catch is CancellationError {
            throw NetworkError.cancelled
        } catch let e as URLError {
            switch e.code {
            case .timedOut: throw NetworkError.timeout
            case .cancelled: throw NetworkError.cancelled
            case .notConnectedToInternet, .networkConnectionLost:
                throw NetworkError.noConnection
            default:
                throw NetworkError.transport(e.localizedDescription)
            }
        } catch {
            throw NetworkError.transport(error.localizedDescription)
        }
    }

    public func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, _) = try await sendData(request)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw NetworkError.decoding(error.localizedDescription)
        }
    }
}
