import Foundation

/// Actor managing file-based persistence of cache entries.
///
/// Each resource gets its own JSON file under `Library/Caches/appactor/http-cache/`.
actor AppActorCacheDiskStore {

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directory: URL? = nil) {
        let dir = directory ?? Self.defaultDirectory
        self.directory = dir

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        self.decoder = dec
    }

    // MARK: - CRUD

    func load(_ resource: AppActorCacheResource) -> AppActorCacheEntry? {
        let url = fileURL(for: resource)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            Log.cache.debug("Cache read failed for \(resource.cacheKey): \(error.localizedDescription)")
            return nil
        }
        do {
            return try decoder.decode(AppActorCacheEntry.self, from: data)
        } catch {
            Log.cache.debug("Cache decode failed for \(resource.cacheKey): \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    func save(_ entry: AppActorCacheEntry, for resource: AppActorCacheResource) {
        let data: Data
        do {
            data = try encoder.encode(entry)
        } catch {
            Log.cache.debug("Cache encode failed for \(resource.cacheKey): \(error.localizedDescription)")
            return
        }
        ensureDirectory()
        do {
            try data.write(to: fileURL(for: resource), options: .atomic)
        } catch {
            Log.cache.debug("Cache write failed for \(resource.cacheKey): \(error.localizedDescription)")
        }
    }

    func updateTimestamp(for resource: AppActorCacheResource, rotatedETag: String? = nil) {
        guard let entry = load(resource) else { return }
        save(entry.refreshed(eTag: rotatedETag), for: resource)
    }

    /// Atomically updates timestamp + returns the updated entry in a single actor call.
    func updateTimestampAndLoad(for resource: AppActorCacheResource, rotatedETag: String? = nil) -> AppActorCacheEntry? {
        guard let entry = load(resource) else { return nil }
        let updated = entry.refreshed(eTag: rotatedETag)
        save(updated, for: resource)
        return updated
    }

    /// Sets `cachedAt` to `.distantPast`, preserving data and eTag for conditional requests.
    /// This makes the cache appear stale so the next fetch goes to the server,
    /// but still sends `If-None-Match` for a potential 304 response.
    func resetFreshness(for resource: AppActorCacheResource) {
        guard let entry = load(resource) else { return }
        save(entry.refreshed(cachedAt: .distantPast), for: resource)
    }

    func clear(_ resource: AppActorCacheResource) {
        try? FileManager.default.removeItem(at: fileURL(for: resource))
    }

    func clearAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Removes all cache files that were stored without response verification.
    /// Keeps verified entries intact. Used for hygiene cleanup at bootstrap
    /// when verification mode is enabled.
    func clearAllUnverified() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let entry = try? decoder.decode(AppActorCacheEntry.self, from: data) else {
                // Corrupt or undecodable — remove
                try? fm.removeItem(at: file)
                continue
            }
            if entry.resolvedVerification == .failed {
                try? fm.removeItem(at: file)
            }
        }
    }

    // MARK: - Internal

    private func fileURL(for resource: AppActorCacheResource) -> URL {
        directory.appendingPathComponent("\(resource.cacheKey).json")
    }

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static var defaultDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("appactor/http-cache", isDirectory: true)
    }
}
