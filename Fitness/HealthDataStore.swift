import Foundation

@MainActor
final class HealthDataStore: ObservableObject {
    enum State {
        case idle
        case loading
        case loaded
        case unavailable(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var runs: [OutdoorRun] = []
    private let healthKit = HealthKitManager()
    private let cache = ProcessedRunCache()
    private var hasLoaded = false

    func load() async {
        guard !hasLoaded else { return }
        state = .loading

        let cached = await cache.load()
        if let cached {
            runs = cached.runs
            hasLoaded = true
            state = .loaded
            if cached.isFresh { return }
        }

        do {
            try await healthKit.requestAuthorization()
            let refreshedRuns = try await healthKit.loadOutdoorRuns()

            // Read authorization denial is intentionally indistinguishable from an
            // empty HealthKit result. Preserve an existing nonempty cache in that case.
            if refreshedRuns.isEmpty, let cached, !cached.runs.isEmpty {
                return
            }

            runs = refreshedRuns
            hasLoaded = true
            state = .loaded
            await cache.save(refreshedRuns)
        } catch {
            if cached == nil {
                state = .unavailable("无法读取健康数据。请在“设置”中允许此 App 读取体能训练数据。")
            }
        }
    }

    func retry() async {
        hasLoaded = false
        await load()
    }
}

private actor ProcessedRunCache {
    struct Snapshot: Sendable {
        let runs: [OutdoorRun]
        let isFresh: Bool
    }

    private struct Payload: Codable {
        let version: Int
        let savedAt: Date
        let runs: [OutdoorRun]
    }

    private let version = 14
    private let freshnessInterval: TimeInterval = 15 * 60

    func load() -> Snapshot? {
        for url in legacyCacheURLs {
            try? FileManager.default.removeItem(at: url)
        }
        do {
            let data = try Data(contentsOf: cacheURL)
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            guard payload.version == version else { return nil }
            return Snapshot(
                runs: payload.runs,
                isFresh: Date().timeIntervalSince(payload.savedAt) < freshnessInterval
            )
        } catch {
            return nil
        }
    }

    func save(_ runs: [OutdoorRun]) {
        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let payload = Payload(version: version, savedAt: Date(), runs: runs)
            let data = try JSONEncoder().encode(payload)
            try data.write(
                to: cacheURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        } catch {
            // Cache failure must not prevent HealthKit data from being displayed.
        }
    }

    private var cacheURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProcessedOutdoorRuns-v14.json", isDirectory: false)
    }

    private var legacyCacheURLs: [URL] {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13].map {
            directory.appendingPathComponent("ProcessedOutdoorRuns-v\($0).json", isDirectory: false)
        }
    }
}
