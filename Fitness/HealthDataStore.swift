import Foundation

@MainActor
final class HealthDataStore: ObservableObject {
    enum State {
        case idle
        case loading
        case loaded
        case unavailable
    }

    enum DataFreshness: Equatable {
        case current
        case stale
    }

    enum DataIssue: Equatable {
        case healthDataUnavailable
        case refreshFailed
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var runs: [OutdoorRun] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var dataFreshness: DataFreshness = .current
    @Published private(set) var dataIssue: DataIssue?
    private let healthKit: any HealthDataLoading
    private let cache: ProcessedRunCache
    private var hasLoaded = false

    init(
        healthKit: any HealthDataLoading = HealthKitManager(),
        cache: ProcessedRunCache = ProcessedRunCache()
    ) {
        self.healthKit = healthKit
        self.cache = cache
    }

    func load() async {
        guard !hasLoaded else { return }
        state = .loading

        let cached = await cache.load()
        if let cached {
            runs = cached.runs
            hasLoaded = true
            state = .loaded
            dataFreshness = cached.isFresh ? .current : .stale
            if cached.isFresh { return }
        }

        do {
            try await healthKit.requestAuthorization()
            let refreshedRuns = try await healthKit.loadOutdoorRuns()

            runs = refreshedRuns
            hasLoaded = true
            state = .loaded
            dataFreshness = .current
            dataIssue = nil
            if refreshedRuns.isEmpty {
                await cache.clear()
            } else {
                await cache.save(refreshedRuns)
            }
        } catch is CancellationError {
            if cached == nil {
                state = .idle
            }
        } catch {
            if cached == nil {
                state = .unavailable
                dataIssue = .healthDataUnavailable
            } else {
                dataFreshness = .stale
                dataIssue = .refreshFailed
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            try await healthKit.requestAuthorization()
            let refreshedRuns = try await healthKit.loadOutdoorRuns()

            runs = refreshedRuns
            hasLoaded = true
            state = .loaded
            dataFreshness = .current
            dataIssue = nil
            if refreshedRuns.isEmpty {
                await cache.clear()
            } else {
                await cache.save(refreshedRuns)
            }
        } catch is CancellationError {
            return
        } catch {
            if runs.isEmpty {
                state = .unavailable
                dataIssue = .healthDataUnavailable
            } else {
                dataFreshness = .stale
                dataIssue = .refreshFailed
            }
        }
    }

    func exportData(for workoutIDs: Set<UUID>) async throws -> [WorkoutHealthExport] {
        try await healthKit.loadWorkoutExportData(for: workoutIDs)
    }

    func elevationData(for workoutID: UUID) async throws -> [ElevationTimelineSample] {
        try await healthKit.loadWorkoutElevationData(for: workoutID)
    }
}

actor ProcessedRunCache {
    struct Snapshot: Sendable {
        let runs: [OutdoorRun]
        let isFresh: Bool
    }

    private struct Payload: Codable {
        let schemaVersion: Int
        let savedAt: Date
        let runs: [OutdoorRun]
    }

    private static let schemaVersion = 5
    private let freshnessInterval: TimeInterval = 15 * 60
    private let cacheURL: URL
    private let legacyCacheURLs: [URL]
    private let applicationSupportLegacyURL: URL?

    init(
        directory: URL? = nil,
        legacyCacheURL: URL? = nil
    ) {
        let fileManager = FileManager.default
        let resolvedDirectory = directory ?? fileManager
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheURL = resolvedDirectory
            .appendingPathComponent("ProcessedOutdoorRuns-v5.json", isDirectory: false)
        if let legacyCacheURL {
            legacyCacheURLs = [legacyCacheURL]
        } else {
            legacyCacheURLs = [
                resolvedDirectory.appendingPathComponent("ProcessedOutdoorRuns-v4.json"),
                resolvedDirectory.appendingPathComponent("ProcessedOutdoorRuns-v3.json"),
                resolvedDirectory.appendingPathComponent("ProcessedOutdoorRuns-v2.json")
            ]
        }
        applicationSupportLegacyURL = directory == nil
            ? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ProcessedOutdoorRuns.json", isDirectory: false)
            : nil
    }

    func load() -> Snapshot? {
        removeLegacyCache()
        do {
            let data = try Data(contentsOf: cacheURL)
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            guard payload.schemaVersion == Self.schemaVersion else {
                try? FileManager.default.removeItem(at: cacheURL)
                return nil
            }
            return Snapshot(
                runs: payload.runs,
                isFresh: Date().timeIntervalSince(payload.savedAt) < freshnessInterval
            )
        } catch {
            return nil
        }
    }

    func save(_ runs: [OutdoorRun]) {
        removeLegacyCache()
        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let payload = Payload(
                schemaVersion: Self.schemaVersion,
                savedAt: Date(),
                runs: runs
            )
            let data = try JSONEncoder().encode(payload)
            try data.write(
                to: cacheURL,
                options: [.atomic, .completeFileProtection]
            )
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var savedURL = cacheURL
            try savedURL.setResourceValues(resourceValues)
        } catch {
            // Cache failure must not prevent HealthKit data from being displayed.
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: cacheURL)
        removeLegacyCache()
    }

    private func removeLegacyCache() {
        for legacyCacheURL in legacyCacheURLs {
            try? FileManager.default.removeItem(at: legacyCacheURL)
        }
        if let applicationSupportLegacyURL {
            try? FileManager.default.removeItem(at: applicationSupportLegacyURL)
        }
    }
}
