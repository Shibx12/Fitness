import Foundation
import HealthKit
import XCTest
@testable import Fitness

final class ProductionSafetyTests: XCTestCase {
    func testProcessedRunCacheRoundTripsInCachesDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ProcessedRunCache(directory: directory)
        let run = makeRun()

        await cache.save([run])
        let snapshot = await cache.load()

        XCTAssertEqual(snapshot?.runs.map(\.id), [run.id])
        XCTAssertEqual(snapshot?.isFresh, true)

        await cache.clear()
        let clearedSnapshot = await cache.load()
        XCTAssertNil(clearedSnapshot)
    }

    func testProcessedRunCacheRejectsOldSchema() async throws {
        struct OldPayload: Encodable {
            let schemaVersion = 4
            let savedAt = Date()
            let runs: [OutdoorRun]
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let cacheURL = directory.appendingPathComponent("ProcessedOutdoorRuns-v5.json")
        let previousCacheURL = directory.appendingPathComponent("ProcessedOutdoorRuns-v4.json")
        try JSONEncoder().encode(OldPayload(runs: [makeRun()])).write(to: cacheURL)
        try Data("obsolete cadence cache".utf8).write(to: previousCacheURL)

        let cache = ProcessedRunCache(directory: directory)
        let snapshot = await cache.load()

        XCTAssertNil(snapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: previousCacheURL.path))
    }

    func testCSVExportIsCreatedOnlyWhenRequestedAndContainsHeader() throws {
        let url = try OutdoorRunCSVExporter.export([makeRun()])
        defer { try? FileManager.default.removeItem(at: url) }

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("\u{FEFF}workout_id,start_date"))
        XCTAssertTrue(content.contains("running_efficiency"))
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey]
                as? FileProtectionType,
            .complete
        )
    }

    func testCSVExportAppendsAuthorizedHealthKitRecordsWithProvenance() throws {
        let run = makeRun()
        let record = WorkoutHealthRecord(
            kind: .routePoint,
            metric: "workout_route",
            startDate: run.startDate,
            endDate: nil,
            value: nil,
            minimum: nil,
            maximum: nil,
            unit: "degrees/meters",
            sourceName: "Apple Watch",
            sourceBundleIdentifier: "com.apple.health",
            device: "Apple Watch | Watch",
            details: "latitude=40.0;longitude=-73.0"
        )
        let url = try OutdoorRunCSVExporter.export(
            [run],
            healthData: [
                WorkoutHealthExport(workoutID: run.id, records: [record])
            ]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("record_kind,record_start_date"))
        XCTAssertTrue(content.contains("workout_route"))
        XCTAssertTrue(content.contains("route_point"))
        XCTAssertTrue(content.contains("Apple Watch"))
        XCTAssertTrue(content.contains("latitude=40.0;longitude=-73.0"))
    }

    @MainActor
    func testRefreshFailureRetainsLastSuccessfulDataAndMarksItStale() async {
        let loader = MockHealthDataLoader(results: [
            .success([makeRun()]),
            .failure(MockError.failed)
        ])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HealthDataStore(
            healthKit: loader,
            cache: ProcessedRunCache(directory: directory)
        )

        await store.load()
        let originalIDs = store.runs.map(\.id)
        await store.refresh()

        XCTAssertEqual(store.runs.map(\.id), originalIDs)
        XCTAssertEqual(store.dataFreshness, .stale)
        XCTAssertEqual(store.dataIssue, .refreshFailed)
    }

    @MainActor
    func testSuccessfulEmptyRefreshClearsDisplayedAndCachedRuns() async {
        let loader = MockHealthDataLoader(results: [
            .success([makeRun()]),
            .success([])
        ])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ProcessedRunCache(directory: directory)
        let store = HealthDataStore(healthKit: loader, cache: cache)

        await store.load()
        await store.refresh()

        XCTAssertTrue(store.runs.isEmpty)
        XCTAssertEqual(store.dataFreshness, .current)
        let snapshot = await cache.load()
        XCTAssertNil(snapshot)
    }

    func testSupportsThreeAppleWorkoutZones() {
        assertSupportedZoneCount(3)
    }

    func testSupportsFiveAppleWorkoutZones() {
        assertSupportedZoneCount(5)
    }

    func testSupportsSixAppleWorkoutZones() {
        assertSupportedZoneCount(6)
    }

    func testSupportsNineAppleWorkoutZones() {
        assertSupportedZoneCount(9)
    }

    func testZoneAggregationReportsConfigurationChangesWithoutBorrowingLatestBounds() {
        let first = makeRun(configuration: makeConfiguration(count: 5, boundaryOffset: 0))
        let second = makeRun(configuration: makeConfiguration(count: 5, boundaryOffset: 5))

        let analysis = HeartRateZoneAnalysis.make(for: [first, second])

        XCTAssertTrue(analysis.hasConfigurationVariation)
        XCTAssertEqual(analysis.summaries.count, 5)
        XCTAssertTrue(analysis.summaries.allSatisfy { $0.boundaries == .varied })
    }

    func testZoneAggregationKeepsMissingWorkoutExplicit() {
        let analysis = HeartRateZoneAnalysis.make(for: [
            makeRun(configuration: makeConfiguration(count: 3)),
            makeRun(configuration: nil)
        ])

        XCTAssertEqual(analysis.workoutCountWithZones, 1)
        XCTAssertEqual(analysis.workoutCountWithoutZones, 1)
        XCTAssertEqual(analysis.summaries.map(\.number), [1, 2, 3])
    }

    func testHeartRateTimelineDetectsRealGapsBeforeChartDownsampling() {
        let segments = HeartRateTimeline.segmentIndices(
            for: [0, 10, 20, 30, 60, 70, 80]
        )

        XCTAssertEqual(segments, [0, 0, 0, 0, 1, 1, 1])
        XCTAssertEqual([segments[0], segments[3], segments[4], segments[6]], [0, 0, 1, 1])
    }

    func testCadenceNormalizesPartialMinuteAndRecordsCoverage() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let stepType = try XCTUnwrap(
            HKObjectType.quantityType(forIdentifier: .stepCount)
        )
        let sample = HKQuantitySample(
            type: stepType,
            quantity: HKQuantity(unit: .count(), doubleValue: 60),
            start: start,
            end: start.addingTimeInterval(30)
        )

        let cadence = HealthDataProcessor.minuteCadence(
            workoutID: UUID(),
            workoutStart: start,
            workoutEnd: start.addingTimeInterval(60),
            samples: [sample],
            deduplicatedStepCounts: [60]
        )

        let first = try XCTUnwrap(cadence.first)
        XCTAssertEqual(first.stepsPerMinute, 120, accuracy: 0.001)
        XCTAssertEqual(first.coverage, 0.5, accuracy: 0.001)
    }

    func testCadenceDoesNotDoubleCountOverlappingHealthKitSources() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let stepType = try XCTUnwrap(
            HKObjectType.quantityType(forIdentifier: .stepCount)
        )
        let overlappingSamples = (0..<2).map { _ in
            HKQuantitySample(
                type: stepType,
                quantity: HKQuantity(unit: .count(), doubleValue: 150),
                start: start,
                end: start.addingTimeInterval(60)
            )
        }

        let cadence = HealthDataProcessor.minuteCadence(
            workoutID: UUID(),
            workoutStart: start,
            workoutEnd: start.addingTimeInterval(60),
            samples: overlappingSamples,
            deduplicatedStepCounts: [150]
        )

        let first = try XCTUnwrap(cadence.first)
        XCTAssertEqual(first.stepsPerMinute, 150, accuracy: 0.001)
        XCTAssertEqual(first.coverage, 1, accuracy: 0.001)
    }

    func testHeartRateIntervalsPreserveRealSamplingGap() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let heartRateType = try XCTUnwrap(
            HKObjectType.quantityType(forIdentifier: .heartRate)
        )
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let samples = [5.0, 205.0].map { offset in
            HKQuantitySample(
                type: heartRateType,
                quantity: HKQuantity(unit: bpm, doubleValue: 140),
                start: start.addingTimeInterval(offset),
                end: start.addingTimeInterval(offset)
            )
        }

        let points = HealthDataProcessor.minuteHeartRate(
            workoutID: UUID(),
            workoutStart: start,
            workoutEnd: start.addingTimeInterval(220),
            samples: samples
        )

        XCTAssertEqual(points.map(\.elapsedSeconds), [0, 200])
    }

    func testRunningEfficiencyUsesDurationWeightedSpeed() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(190)
        let heartRateType = try XCTUnwrap(
            HKObjectType.quantityType(forIdentifier: .heartRate)
        )
        let speedType = try XCTUnwrap(
            HKObjectType.quantityType(forIdentifier: .runningSpeed)
        )
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let speedUnit = HKUnit.meter().unitDivided(by: .second())
        var heartRates: [HKQuantitySample] = []
        var speeds: [HKQuantitySample] = []
        for interval in 0..<19 {
            let intervalStart = start.addingTimeInterval(Double(interval * 10))
            heartRates.append(HKQuantitySample(
                type: heartRateType,
                quantity: HKQuantity(unit: bpm, doubleValue: 120),
                start: intervalStart.addingTimeInterval(5),
                end: intervalStart.addingTimeInterval(5)
            ))
            speeds.append(HKQuantitySample(
                type: speedType,
                quantity: HKQuantity(unit: speedUnit, doubleValue: 2),
                start: intervalStart,
                end: intervalStart.addingTimeInterval(9)
            ))
            speeds.append(HKQuantitySample(
                type: speedType,
                quantity: HKQuantity(unit: speedUnit, doubleValue: 6),
                start: intervalStart.addingTimeInterval(9),
                end: intervalStart.addingTimeInterval(10)
            ))
        }

        let result = HealthDataProcessor.runningMetrics(
            workoutStart: start,
            workoutEnd: end,
            heartRateSamples: heartRates,
            speedSamples: speeds,
            distanceSamples: [],
            workoutEvents: []
        ).runningEfficiency

        XCTAssertEqual(result.status, .available)
        XCTAssertEqual(
            try XCTUnwrap(result.averageSpeedKilometersPerHour),
            8.64,
            accuracy: 0.001
        )
    }

    func testRunningTimelineUsesHealthKitSpeedHeartRateAndStride() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let heartRateType = try XCTUnwrap(
            HKObjectType.quantityType(forIdentifier: .heartRate)
        )
        let speedType = try XCTUnwrap(
            HKObjectType.quantityType(forIdentifier: .runningSpeed)
        )
        let strideType = try XCTUnwrap(
            HKObjectType.quantityType(forIdentifier: .runningStrideLength)
        )
        let heartRate = HKQuantitySample(
            type: heartRateType,
            quantity: HKQuantity(
                unit: HKUnit.count().unitDivided(by: .minute()),
                doubleValue: 150
            ),
            start: start.addingTimeInterval(5),
            end: start.addingTimeInterval(5)
        )
        let speed = HKQuantitySample(
            type: speedType,
            quantity: HKQuantity(
                unit: HKUnit.meter().unitDivided(by: .second()),
                doubleValue: 4
            ),
            start: start,
            end: start.addingTimeInterval(10)
        )
        let stride = HKQuantitySample(
            type: strideType,
            quantity: HKQuantity(unit: .meter(), doubleValue: 1.2),
            start: start,
            end: start.addingTimeInterval(10)
        )

        let metrics = HealthDataProcessor.runningMetrics(
            workoutStart: start,
            workoutEnd: start.addingTimeInterval(10),
            heartRateSamples: [heartRate],
            speedSamples: [speed],
            distanceSamples: [],
            workoutEvents: [],
            strideLengthSamples: [stride]
        )

        let point = try XCTUnwrap(metrics.runningTimeline.first)
        XCTAssertEqual(point.elapsedSeconds, 0)
        XCTAssertEqual(point.heartRateBPM, 150, accuracy: 0.001)
        XCTAssertEqual(point.paceSecondsPerKilometer, 250, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(point.strideLengthMeters), 1.2, accuracy: 0.001)
    }

    func testRunningWarmupUsesWorkoutElapsedTimeAcrossPause() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(300)
        let heartRateType = try XCTUnwrap(
            HKObjectType.quantityType(forIdentifier: .heartRate)
        )
        let speedType = try XCTUnwrap(
            HKObjectType.quantityType(forIdentifier: .runningSpeed)
        )
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let speedUnit = HKUnit.meter().unitDivided(by: .second())
        let activeIntervals = [0, 10] + Array(stride(from: 200, to: 300, by: 10))
        let heartRates = activeIntervals.map { offset in
            HKQuantitySample(
                type: heartRateType,
                quantity: HKQuantity(unit: bpm, doubleValue: 130),
                start: start.addingTimeInterval(Double(offset + 5)),
                end: start.addingTimeInterval(Double(offset + 5))
            )
        }
        let speeds = activeIntervals.map { offset in
            HKQuantitySample(
                type: speedType,
                quantity: HKQuantity(unit: speedUnit, doubleValue: 3),
                start: start.addingTimeInterval(Double(offset)),
                end: start.addingTimeInterval(Double(offset + 10))
            )
        }
        let events = [
            HKWorkoutEvent(
                type: .pause,
                dateInterval: DateInterval(start: start.addingTimeInterval(20), duration: 0),
                metadata: nil
            ),
            HKWorkoutEvent(
                type: .resume,
                dateInterval: DateInterval(start: start.addingTimeInterval(200), duration: 0),
                metadata: nil
            )
        ]

        let result = HealthDataProcessor.runningMetrics(
            workoutStart: start,
            workoutEnd: end,
            heartRateSamples: heartRates,
            speedSamples: speeds,
            distanceSamples: [],
            workoutEvents: events
        ).runningEfficiency

        XCTAssertEqual(result.status, .available)
        XCTAssertEqual(result.effectiveDuration, 100, accuracy: 0.001)
    }

    func testChartWindowBoundsLongHistoryRenderingWork() {
        let paceRange = ChartWindow.range(
            itemCount: 10_000,
            visibleCount: 10,
            scrollPosition: 5_000,
            padding: 6
        )
        let cadenceRange = ChartWindow.range(
            itemCount: 10_000,
            visibleCount: 20,
            scrollPosition: 9_999,
            padding: 8
        )

        XCTAssertEqual(paceRange.count, 22)
        XCTAssertTrue(paceRange.contains(5_000))
        XCTAssertEqual(cadenceRange.count, 36)
        XCTAssertEqual(cadenceRange.upperBound, 10_000)
    }

    func testElevationChartSamplingKeepsEndpointsAndMaximumCount() {
        let samples = (0..<1_000).map {
            ElevationTimelineSample(elapsedSeconds: $0, meters: Double($0))
        }

        let displayed = ElevationTimeline.samplesForChart(samples, maximumCount: 100)

        XCTAssertEqual(displayed.count, 100)
        XCTAssertEqual(displayed.first?.elapsedSeconds, 0)
        XCTAssertEqual(displayed.last?.elapsedSeconds, 999)
    }

    private func makeRun(
        configuration: WorkoutHeartRateZoneConfiguration? = nil
    ) -> OutdoorRun {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return OutdoorRun(
            id: UUID(),
            startDate: start,
            endDate: start.addingTimeInterval(600),
            duration: 600,
            distanceKm: 1.5,
            kilometerSplits: [],
            minuteHeartRateData: [],
            minuteCadenceData: [],
            runningEfficiency: .insufficient(),
            effectiveRunningHeartRates: [],
            runningTimelineData: [],
            heartRateZoneConfiguration: configuration
        )
    }

    private func assertSupportedZoneCount(_ count: Int) {
        let configuration = makeConfiguration(count: count)
        let analysis = HeartRateZoneAnalysis.make(for: [
            makeRun(configuration: configuration)
        ])

        XCTAssertEqual(configuration.zoneCount, count)
        XCTAssertEqual(analysis.summaries.map(\.number), Array(1...count))
        XCTAssertFalse(analysis.hasConfigurationVariation)
        XCTAssertEqual(
            analysis.summaries.reduce(0) { $0 + $1.percentage },
            100,
            accuracy: 0.001
        )
    }

    private func makeConfiguration(
        count: Int,
        boundaryOffset: Double = 0
    ) -> WorkoutHeartRateZoneConfiguration {
        WorkoutHeartRateZoneConfiguration(
            source: .systemAutomatic,
            zones: (1...count).map { number in
                WorkoutHeartRateZone(
                    number: number,
                    duration: Double(number * 60),
                    minimumBPM: number == 1
                        ? nil
                        : 90 + Double(number * 10) + boundaryOffset,
                    maximumBPM: number == count
                        ? nil
                        : 100 + Double(number * 10) + boundaryOffset
                )
            }
        )
    }
}

private enum MockError: Error, Sendable {
    case failed
}

private actor MockHealthDataLoader: HealthDataLoading {
    private var results: [Result<[OutdoorRun], MockError>]

    init(results: [Result<[OutdoorRun], MockError>]) {
        self.results = results
    }

    func requestAuthorization() async throws {}

    func loadOutdoorRuns() async throws -> [OutdoorRun] {
        guard !results.isEmpty else { return [] }
        return try results.removeFirst().get()
    }
}
