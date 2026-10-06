import Foundation
import CryptoKit

/// Every network call goes through this, so tests can replay recorded responses and never
/// touch the network (CLAUDE.md).
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct HTTPError: Error, LocalizedError, Sendable {
    public let status: Int
    public let retryAfter: TimeInterval?
    public var errorDescription: String? { "HTTP \(status)" }
}

/// The live transport: ephemeral session (no shared cookies or cache), explicit timeouts, and a
/// User-Agent that names the project, as Overpass and Wikimedia ask.
public struct URLSessionTransport: HTTPTransport {
    public static let userAgent = "TourGuide/0.1 (https://github.com/MonkeyBonez/TourGuide)"
    let session: URLSession

    public init(requestTimeout: TimeInterval = 30, resourceTimeout: TimeInterval = 60) {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = requestTimeout
        c.timeoutIntervalForResource = resourceTimeout
        c.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        session = URLSession(configuration: c)
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Record/replay keyed by a hash of method + URL + body. `record` passes through to a real
/// transport and writes what came back; `replay` serves only what is on disk.
public final class FixtureTransport: HTTPTransport, @unchecked Sendable {
    public enum Mode: Sendable { case replay, record(HTTPTransport) }
    public let directory: URL
    public let mode: Mode
    /// Canned answers by host, consumed in order (for mirror-failure tests). A nil Data = timeout.
    private var scripted: [String: [(Int, Data?)]] = [:]
    private let lock = NSLock()
    public private(set) var requests: [URLRequest] = []

    public init(directory: URL, mode: Mode = .replay) { self.directory = directory; self.mode = mode }

    public func script(host: String, _ responses: [(Int, Data?)]) { lock.withLock { scripted[host, default: []] += responses } }

    public static func key(for r: URLRequest) -> String {
        let s = (r.httpMethod ?? "GET") + " " + (r.url?.absoluteString ?? "") + " " + String(decoding: r.httpBody ?? Data(), as: UTF8.self)
        return Insecure.SHA1.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let host = request.url?.host ?? ""
        let canned: (Int, Data?)? = lock.withLock {
            requests.append(request)
            guard var list = scripted[host], !list.isEmpty else { return nil }
            let first = list.removeFirst(); scripted[host] = list; return first
        }
        if let (status, body) = canned {
            guard let body else { throw URLError(.timedOut) }
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        let file = directory.appendingPathComponent(Self.key(for: request) + ".bin")
        switch mode {
        case .replay:
            guard let stored = try? Data(contentsOf: file) else {
                throw URLError(.resourceUnavailable, userInfo: [NSURLErrorFailingURLStringErrorKey: request.url?.absoluteString ?? ""])
            }
            let status = Int(String(decoding: stored.prefix(3), as: UTF8.self)) ?? 200
            return (stored.dropFirst(4), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        case .record(let live):
            let (data, response) = try await live.data(for: request)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try (Data(String(format: "%03d\n", response.statusCode).utf8) + data).write(to: file)
            return (data, response)
        }
    }
}

extension HTTPTransport {
    /// GET/POST, 2xx or `HTTPError`.
    func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            let ra = (response.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            throw HTTPError(status: response.statusCode, retryAfter: ra)
        }
        return data
    }
}

func formBody(_ fields: [String: String]) -> Data {
    var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
    return Data(fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
        .sorted().joined(separator: "&").utf8)
}
