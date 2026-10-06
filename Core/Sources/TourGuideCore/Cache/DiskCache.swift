import Foundation
import CryptoKit

/// Codable values on disk by key, with a time-to-live. Fetched corridors (30 days), card content
/// (7 days), translations (no expiry).
public final class DiskCache: @unchecked Sendable {
    public let directory: URL
    public let ttl: TimeInterval

    public init(directory: URL, ttl: TimeInterval) {
        self.directory = directory; self.ttl = ttl
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// `Caches/tourguide/<name>` on device; `~/Library/Caches/tourguide/<name>` for tgtool.
    public static func named(_ name: String, ttl: TimeInterval) -> DiskCache {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return DiskCache(directory: base.appendingPathComponent("tourguide/\(name)"), ttl: ttl)
    }

    func url(_ key: String) -> URL {
        let h = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(h + ".json")
    }

    public func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        let u = url(key)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: u.path),
              let date = attrs[.modificationDate] as? Date, Date().timeIntervalSince(date) < ttl,
              let data = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public func store<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url(key), options: .atomic)
    }

    public func remove(key: String) { try? FileManager.default.removeItem(at: url(key)) }
}
