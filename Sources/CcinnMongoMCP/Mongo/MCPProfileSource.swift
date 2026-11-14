import CcinnMongoKit
import Foundation
import os

/// Supplies the saved profiles for each call, so edits made in the app apply without a restart.
public protocol MCPProfileSource: Sendable {
    func loadProfiles() throws -> [ConnectionProfile]
}

/// Reads `connections.json`, re-decoding only when the file's size or modification time changed.
public final class ProfileFileSource: MCPProfileSource {
    private struct CacheKey: Equatable, Sendable {
        let modified: Date
        let size: UInt64
    }

    private let repository: ProfileRepository
    private let cache = OSAllocatedUnfairLock<(key: CacheKey, profiles: [ConnectionProfile])?>(initialState: nil)

    public init(repository: ProfileRepository) {
        self.repository = repository
    }

    public func loadProfiles() throws -> [ConnectionProfile] {
        let url = repository.directory.appendingPathComponent("connections.json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else {
            cache.withLock { $0 = nil }
            return []
        }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let key = CacheKey(modified: modified, size: size)
        if let cached = cache.withLock({ $0 }), cached.key == key { return cached.profiles }
        let profiles = try repository.load()
        cache.withLock { $0 = (key, profiles) }
        return profiles
    }
}
