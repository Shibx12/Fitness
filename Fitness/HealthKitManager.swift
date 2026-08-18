import Foundation
import CoreLocation
import HealthKit

protocol HealthDataLoading: Sendable {
    func requestAuthorization() async throws
    func loadOutdoorRuns() async throws -> [OutdoorRun]
    func loadWorkoutExportData(for workoutIDs: Set<UUID>) async throws -> [WorkoutHealthExport]
    func loadWorkoutElevationData(for workoutID: UUID) async throws -> [ElevationTimelineSample]
}

extension HealthDataLoading {
    func loadWorkoutExportData(for workoutIDs: Set<UUID>) async throws -> [WorkoutHealthExport] {
        []
    }

    func loadWorkoutElevationData(for workoutID: UUID) async throws -> [ElevationTimelineSample] {
        []
    }
}

actor HealthKitManager: HealthDataLoading {
    enum Error: Swift.Error {
        case unavailable
        case missingTypes
    }

    private let store = HKHealthStore()

    private var workoutType: HKWorkoutType { HKObjectType.workoutType() }
    private var distanceType: HKQuantityType? {
        HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)
    }
    private var heartRateType: HKQuantityType? {
        HKObjectType.quantityType(forIdentifier: .heartRate)
    }
    private var runningSpeedType: HKQuantityType? {
        HKObjectType.quantityType(forIdentifier: .runningSpeed)
    }
    private var stepType: HKQuantityType? {
        HKObjectType.quantityType(forIdentifier: .stepCount)
    }
    private var runningStrideLengthType: HKQuantityType? {
        HKObjectType.quantityType(forIdentifier: .runningStrideLength)
    }

    private struct ExportQuantityDescriptor: Sendable {
        let type: HKQuantityType
        let unit: HKUnit
        let unitLabel: String
    }

    private var exportQuantityDescriptors: [ExportQuantityDescriptor] {
        [
            exportDescriptor(.activeEnergyBurned, unit: "kcal"),
            exportDescriptor(.appleExerciseTime, unit: "min"),
            exportDescriptor(.appleMoveTime, unit: "min"),
            exportDescriptor(.appleStandTime, unit: "min"),
            exportDescriptor(.basalEnergyBurned, unit: "kcal"),
            exportDescriptor(.distanceWalkingRunning, unit: "m"),
            exportDescriptor(.estimatedWorkoutEffortScore, unit: "appleEffortScore"),
            exportDescriptor(.flightsClimbed, unit: "count"),
            exportDescriptor(.heartRate, unit: "count/min", label: "bpm"),
            exportDescriptor(.heartRateRecoveryOneMinute, unit: "count/min", label: "bpm"),
            exportDescriptor(.physicalEffort, unit: "kcal/(kg*hr)"),
            exportDescriptor(.runningGroundContactTime, unit: "ms"),
            exportDescriptor(.runningPower, unit: "W"),
            exportDescriptor(.runningSpeed, unit: "m/s"),
            exportDescriptor(.runningStrideLength, unit: "m"),
            exportDescriptor(.runningVerticalOscillation, unit: "cm"),
            exportDescriptor(.stepCount, unit: "count"),
            exportDescriptor(.workoutEffortScore, unit: "appleEffortScore")
        ].compactMap { $0 }
    }

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw Error.unavailable }
        guard distanceType != nil, heartRateType != nil, stepType != nil else {
            throw Error.missingTypes
        }
        var readTypes: Set<HKObjectType> = [
            workoutType,
            distanceType!,
            heartRateType!,
            stepType!
        ]
        if let runningSpeedType { readTypes.insert(runningSpeedType) }
        if let runningStrideLengthType { readTypes.insert(runningStrideLengthType) }
        try await store.requestAuthorization(
            toShare: [],
            read: readTypes
        )
    }

    func loadOutdoorRuns() async throws -> [OutdoorRun] {
        guard let distanceType, let heartRateType, let stepType else { throw Error.missingTypes }
        let running = HKQuery.predicateForWorkouts(with: .running)
        let workoutQuery = HKSampleQueryDescriptor(
            predicates: [.workout(running)],
            sortDescriptors: []
        )
        let workouts = try await workoutQuery.result(for: store)
            .sorted { $0.startDate < $1.startDate }

        let outdoorWorkouts = workouts.filter(isOutdoor)
        return try await withThrowingTaskGroup(of: (Int, OutdoorRun).self) { group in
            let maximumConcurrentWorkouts = 3
            var nextIndex = 0
            var results = Array<OutdoorRun?>(repeating: nil, count: outdoorWorkouts.count)

            func addNextWorkout() {
                guard nextIndex < outdoorWorkouts.count else { return }
                let index = nextIndex
                let workout = outdoorWorkouts[index]
                nextIndex += 1
                group.addTask { [self] in
                    try Task.checkCancellation()
                    return (
                        index,
                        try await outdoorRun(
                            from: workout,
                            distanceType: distanceType,
                            heartRateType: heartRateType,
                            stepType: stepType
                        )
                    )
                }
            }

            for _ in 0..<min(maximumConcurrentWorkouts, outdoorWorkouts.count) {
                addNextWorkout()
            }
            while let (index, run) = try await group.next() {
                results[index] = run
                addNextWorkout()
            }
            return results.compactMap { $0 }
        }
    }

    func loadWorkoutExportData(
        for workoutIDs: Set<UUID>
    ) async throws -> [WorkoutHealthExport] {
        guard !workoutIDs.isEmpty else { return [] }
        try await requestExportAuthorization()
        let predicate = HKQuery.predicateForObjects(with: workoutIDs)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: []
        )
        let workouts = try await descriptor.result(for: store)
            .sorted { $0.startDate < $1.startDate }

        var exports: [WorkoutHealthExport] = []
        exports.reserveCapacity(workouts.count)
        for workout in workouts {
            try Task.checkCancellation()
            exports.append(
                WorkoutHealthExport(
                    workoutID: workout.uuid,
                    records: try await exportRecords(for: workout)
                )
            )
        }
        return exports
    }

    func loadWorkoutElevationData(
        for workoutID: UUID
    ) async throws -> [ElevationTimelineSample] {
        try await store.requestAuthorization(
            toShare: [],
            read: [workoutType, HKSeriesType.workoutRoute()]
        )
        let predicate = HKQuery.predicateForObject(with: workoutID)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: []
        )
        guard let workout = try await descriptor.result(for: store).first else {
            return []
        }
        let routePredicate = HKQuery.predicateForObjects(from: workout)
        let routeDescriptor = HKSampleQueryDescriptor(
            predicates: [.workoutRoute(routePredicate)],
            sortDescriptors: []
        )
        let routes = try await routeDescriptor.result(for: store)
        var samples: [ElevationTimelineSample] = []
        for route in routes {
            for try await location in HKWorkoutRouteQueryDescriptor(route).results(for: store) {
                try Task.checkCancellation()
                let elapsed = location.timestamp.timeIntervalSince(workout.startDate)
                guard elapsed >= 0,
                      location.timestamp <= workout.endDate,
                      location.altitude.isFinite,
                      location.verticalAccuracy >= 0 else { continue }
                samples.append(ElevationTimelineSample(
                    elapsedSeconds: Int(elapsed.rounded()),
                    meters: location.altitude
                ))
            }
        }
        var sampleBySecond: [Int: ElevationTimelineSample] = [:]
        for sample in samples {
            sampleBySecond[sample.elapsedSeconds] = sample
        }
        return sampleBySecond.values.sorted { $0.elapsedSeconds < $1.elapsedSeconds }
    }

    private func requestExportAuthorization() async throws {
        var readTypes = Set<HKObjectType>(exportQuantityDescriptors.map(\.type))
        readTypes.insert(workoutType)
        readTypes.insert(HKSeriesType.workoutRoute())
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    private func outdoorRun(
        from workout: HKWorkout,
        distanceType: HKQuantityType,
        heartRateType: HKQuantityType,
        stepType: HKQuantityType
    ) async throws -> OutdoorRun {
        async let distanceSamplesResult = quantitySamples(type: distanceType, workout: workout)
        async let heartRateSamplesResult = quantitySamples(type: heartRateType, workout: workout)
        async let speedSamplesResult = optionalQuantitySamples(type: runningSpeedType, workout: workout)
        async let strideSamplesResult = optionalQuantitySamples(
            type: runningStrideLengthType,
            workout: workout
        )
        async let stepSamplesResult = quantitySamples(type: stepType, workout: workout)
        async let stepCountsResult = deduplicatedStepCounts(type: stepType, workout: workout)
        let (
            distanceSamples,
            heartRateSamples,
            speedSamples,
            strideSamples,
            stepSamples,
            stepCounts
        ) = try await (
            distanceSamplesResult,
            heartRateSamplesResult,
            speedSamplesResult,
            strideSamplesResult,
            stepSamplesResult,
            stepCountsResult
        )
        let id = workout.uuid
        let runningMetrics = HealthDataProcessor.runningMetrics(
            workoutStart: workout.startDate,
            workoutEnd: workout.endDate,
            heartRateSamples: heartRateSamples,
            speedSamples: speedSamples,
            distanceSamples: distanceSamples,
            workoutEvents: workout.workoutEvents ?? [],
            strideLengthSamples: strideSamples
        )
        return OutdoorRun(
            id: id,
            startDate: workout.startDate,
            endDate: workout.endDate,
            duration: workout.duration,
            distanceKm: workout.statistics(for: distanceType)?.sumQuantity()?
                .doubleValue(for: .meterUnit(with: .kilo))
                ?? distanceSamples.reduce(0) {
                    $0 + $1.quantity.doubleValue(for: .meterUnit(with: .kilo))
                },
            kilometerSplits: HealthDataProcessor.kilometerSplits(
                workoutID: id,
                workoutStart: workout.startDate,
                workoutEnd: workout.endDate,
                samples: distanceSamples
            ),
            minuteHeartRateData: HealthDataProcessor.minuteHeartRate(
                workoutID: id,
                workoutStart: workout.startDate,
                workoutEnd: workout.endDate,
                samples: heartRateSamples
            ),
            minuteCadenceData: HealthDataProcessor.minuteCadence(
                workoutID: id,
                workoutStart: workout.startDate,
                workoutEnd: workout.endDate,
                samples: stepSamples,
                deduplicatedStepCounts: stepCounts
            ),
            runningEfficiency: runningMetrics.runningEfficiency,
            effectiveRunningHeartRates: runningMetrics.effectiveRunningHeartRates,
            runningTimelineData: runningMetrics.runningTimeline,
            heartRateZoneConfiguration: heartRateZoneConfiguration(
                for: workout,
                heartRateType: heartRateType
            )
        )
    }

    private func deduplicatedStepCounts(
        type: HKQuantityType,
        workout: HKWorkout
    ) async throws -> [Double?] {
        let completeMinutes = max(0, Int(workout.endDate.timeIntervalSince(workout.startDate) / 60))
        guard completeMinutes > 0 else { return [] }
        let completeWorkoutEnd = workout.startDate.addingTimeInterval(
            Double(completeMinutes) * 60
        )
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: workout),
            HKQuery.predicateForSamples(
                withStart: workout.startDate,
                end: completeWorkoutEnd,
                options: []
            )
        ])
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: type, predicate: predicate),
            options: .cumulativeSum,
            anchorDate: workout.startDate,
            intervalComponents: DateComponents(minute: 1)
        )
        let collection = try await descriptor.result(for: store)
        return (0..<completeMinutes).map { minute in
            let date = workout.startDate.addingTimeInterval(Double(minute) * 60)
            return collection.statistics(for: date)?.sumQuantity()?
                .doubleValue(for: .count())
        }
    }

    private func heartRateZoneConfiguration(
        for workout: HKWorkout,
        heartRateType: HKQuantityType
    ) -> WorkoutHeartRateZoneConfiguration? {
        guard let group = workout.zoneGroup(for: heartRateType) else { return nil }
        let bpm = HKUnit.count().unitDivided(by: .minute())
        var durationByIndex: [Int: TimeInterval] = [:]
        for zoneDuration in group.zoneDurations {
            durationByIndex[zoneDuration.zone.index, default: 0] += zoneDuration.duration
        }
        let source: WorkoutHeartRateZoneConfiguration.Source
        switch group.configuration.source {
        case .system:
            source = .systemAutomatic
        case .user:
            source = .userCustom
        case .app:
            source = .appCustom
        @unknown default:
            source = .unknown
        }

        let zones = group.configuration.zones
            .map { zone in
                WorkoutHeartRateZone(
                    number: zone.index + 1,
                    duration: durationByIndex[zone.index] ?? 0,
                    minimumBPM: zone.minimum?.doubleValue(for: bpm),
                    maximumBPM: zone.maximum?.doubleValue(for: bpm)
                )
            }
            .sorted { $0.number < $1.number }
        guard (3...9).contains(zones.count) else { return nil }
        return WorkoutHeartRateZoneConfiguration(source: source, zones: zones)
    }

    private func isOutdoor(_ workout: HKWorkout) -> Bool {
        // HealthKit reliably identifies treadmill runs as indoor when this metadata
        // is present. Ambiguous running workouts are retained because route access
        // is not required by this app and absence of metadata does not mean indoor.
        if let indoor = workout.metadata?[HKMetadataKeyIndoorWorkout] as? Bool {
            return !indoor
        }
        return true
    }

    private func quantitySamples(type: HKQuantityType, workout: HKWorkout) async throws -> [HKQuantitySample] {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: workout),
            HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: [])
        ])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type, predicate: predicate)],
            sortDescriptors: []
        )
        return try await descriptor.result(for: store)
            .sorted { $0.startDate < $1.startDate }
    }

    private func optionalQuantitySamples(
        type: HKQuantityType?,
        workout: HKWorkout
    ) async throws -> [HKQuantitySample] {
        guard let type else { return [] }
        return try await quantitySamples(type: type, workout: workout)
    }

    private func exportDescriptor(
        _ identifier: HKQuantityTypeIdentifier,
        unit: String,
        label: String? = nil
    ) -> ExportQuantityDescriptor? {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else {
            return nil
        }
        return ExportQuantityDescriptor(
            type: type,
            unit: HKUnit(from: unit),
            unitLabel: label ?? unit
        )
    }

    private func exportRecords(for workout: HKWorkout) async throws -> [WorkoutHealthRecord] {
        let sourceName = workout.sourceRevision.source.name
        let sourceBundle = workout.sourceRevision.source.bundleIdentifier
        let device = deviceDescription(workout.device)
        var records = [WorkoutHealthRecord(
            kind: .workout,
            metric: "workout_summary",
            startDate: workout.startDate,
            endDate: workout.endDate,
            value: workout.duration,
            minimum: nil,
            maximum: nil,
            unit: "seconds",
            sourceName: sourceName,
            sourceBundleIdentifier: sourceBundle,
            device: device,
            details: [
                "activity_type=\(workout.workoutActivityType.rawValue)",
                sourceRevisionDescription(workout.sourceRevision)
            ].joined(separator: ";")
        )]

        records.append(contentsOf: metadataRecords(
            workout.metadata,
            metricPrefix: "workout",
            startDate: workout.startDate,
            endDate: workout.endDate,
            sourceName: sourceName,
            sourceBundle: sourceBundle,
            device: device
        ))
        records.append(contentsOf: eventRecords(
            workout.workoutEvents ?? [],
            sourceName: sourceName,
            sourceBundle: sourceBundle,
            device: device
        ))

        for (index, activity) in workout.workoutActivities.enumerated() {
            records.append(WorkoutHealthRecord(
                kind: .activity,
                metric: "workout_activity",
                startDate: activity.startDate,
                endDate: activity.endDate,
                value: activity.duration,
                minimum: nil,
                maximum: nil,
                unit: "seconds",
                sourceName: sourceName,
                sourceBundleIdentifier: sourceBundle,
                device: device,
                details: [
                    "index=\(index + 1)",
                    "activity_uuid=\(activity.uuid.uuidString)",
                    "activity_type=\(activity.workoutConfiguration.activityType.rawValue)",
                    "location_type=\(activity.workoutConfiguration.locationType.rawValue)"
                ].joined(separator: ";")
            ))
            records.append(contentsOf: metadataRecords(
                activity.metadata,
                metricPrefix: "activity_\(index + 1)",
                startDate: activity.startDate,
                endDate: activity.endDate,
                sourceName: sourceName,
                sourceBundle: sourceBundle,
                device: device
            ))
            for descriptor in exportQuantityDescriptors {
                guard let statistics = activity.statistics(for: descriptor.type) else {
                    continue
                }
                records.append(statisticsRecord(
                    statistics,
                    descriptor: descriptor,
                    startDate: activity.startDate,
                    endDate: activity.endDate ?? workout.endDate,
                    sourceName: sourceName,
                    sourceBundle: sourceBundle,
                    device: device,
                    context: "activity_index=\(index + 1)"
                ))
            }
        }

        for descriptor in exportQuantityDescriptors {
            try Task.checkCancellation()
            if let statistics = workout.statistics(for: descriptor.type) {
                records.append(statisticsRecord(
                    statistics,
                    descriptor: descriptor,
                    startDate: workout.startDate,
                    endDate: workout.endDate,
                    sourceName: sourceName,
                    sourceBundle: sourceBundle,
                    device: device
                ))
            }
            let samples = try await quantitySamples(type: descriptor.type, workout: workout)
            records.append(contentsOf: samples.map { sample in
                WorkoutHealthRecord(
                    kind: .quantitySample,
                    metric: descriptor.type.identifier,
                    startDate: sample.startDate,
                    endDate: sample.endDate,
                    value: sample.quantity.doubleValue(for: descriptor.unit),
                    minimum: nil,
                    maximum: nil,
                    unit: descriptor.unitLabel,
                    sourceName: sample.sourceRevision.source.name,
                    sourceBundleIdentifier: sample.sourceRevision.source.bundleIdentifier,
                    device: deviceDescription(sample.device),
                    details: [
                        "sample_uuid=\(sample.uuid.uuidString)",
                        sourceRevisionDescription(sample.sourceRevision),
                        metadataDescription(sample.metadata)
                    ].filter { !$0.isEmpty }.joined(separator: ";")
                )
            })
        }

        if let heartRateType,
           let zoneConfiguration = heartRateZoneConfiguration(
               for: workout,
               heartRateType: heartRateType
           ) {
            records.append(contentsOf: zoneConfiguration.zones.map { zone in
                WorkoutHealthRecord(
                    kind: .heartRateZone,
                    metric: "apple_workout_zone_\(zone.number)",
                    startDate: workout.startDate,
                    endDate: workout.endDate,
                    value: zone.duration,
                    minimum: zone.minimumBPM,
                    maximum: zone.maximumBPM,
                    unit: "seconds; bounds=bpm",
                    sourceName: sourceName,
                    sourceBundleIdentifier: sourceBundle,
                    device: device,
                    details: "configuration_source=\(zoneConfiguration.source.rawValue)"
                )
            })
        }

        records.append(contentsOf: try await routeRecords(
            for: workout,
            sourceName: sourceName,
            sourceBundle: sourceBundle,
            device: device
        ))
        return records
    }

    private func statisticsRecord(
        _ statistics: HKStatistics,
        descriptor: ExportQuantityDescriptor,
        startDate: Date,
        endDate: Date,
        sourceName: String,
        sourceBundle: String,
        device: String,
        context: String = "workout"
    ) -> WorkoutHealthRecord {
        let sum = statistics.sumQuantity()?.doubleValue(for: descriptor.unit)
        let average = statistics.averageQuantity()?.doubleValue(for: descriptor.unit)
        return WorkoutHealthRecord(
            kind: .statistic,
            metric: descriptor.type.identifier,
            startDate: startDate,
            endDate: endDate,
            value: sum ?? average,
            minimum: statistics.minimumQuantity()?.doubleValue(for: descriptor.unit),
            maximum: statistics.maximumQuantity()?.doubleValue(for: descriptor.unit),
            unit: descriptor.unitLabel,
            sourceName: sourceName,
            sourceBundleIdentifier: sourceBundle,
            device: device,
            details: [
                context,
                sum == nil
                    ? "value=average"
                    : "value=sum;average=\(optionalNumber(average))"
            ].joined(separator: ";")
        )
    }

    private func eventRecords(
        _ events: [HKWorkoutEvent],
        sourceName: String,
        sourceBundle: String,
        device: String
    ) -> [WorkoutHealthRecord] {
        events.map { event in
            WorkoutHealthRecord(
                kind: .event,
                metric: workoutEventName(event.type),
                startDate: event.dateInterval.start,
                endDate: event.dateInterval.end,
                value: event.dateInterval.duration,
                minimum: nil,
                maximum: nil,
                unit: "seconds",
                sourceName: sourceName,
                sourceBundleIdentifier: sourceBundle,
                device: device,
                details: metadataDescription(event.metadata)
            )
        }
    }

    private func metadataRecords(
        _ metadata: [String: Any]?,
        metricPrefix: String,
        startDate: Date,
        endDate: Date?,
        sourceName: String,
        sourceBundle: String,
        device: String
    ) -> [WorkoutHealthRecord] {
        (metadata ?? [:]).keys.sorted().map { key in
            WorkoutHealthRecord(
                kind: .metadata,
                metric: "\(metricPrefix).\(key)",
                startDate: startDate,
                endDate: endDate,
                value: nil,
                minimum: nil,
                maximum: nil,
                unit: "",
                sourceName: sourceName,
                sourceBundleIdentifier: sourceBundle,
                device: device,
                details: metadataValueDescription(metadata?[key])
            )
        }
    }

    private func routeRecords(
        for workout: HKWorkout,
        sourceName: String,
        sourceBundle: String,
        device: String
    ) async throws -> [WorkoutHealthRecord] {
        let predicate = HKQuery.predicateForObjects(from: workout)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workoutRoute(predicate)],
            sortDescriptors: []
        )
        let routes = try await descriptor.result(for: store)
        var records: [WorkoutHealthRecord] = []
        for route in routes {
            records.append(WorkoutHealthRecord(
                kind: .metadata,
                metric: "workout_route",
                startDate: route.startDate,
                endDate: route.endDate,
                value: nil,
                minimum: nil,
                maximum: nil,
                unit: "",
                sourceName: route.sourceRevision.source.name,
                sourceBundleIdentifier: route.sourceRevision.source.bundleIdentifier,
                device: deviceDescription(route.device),
                details: [
                    "route_uuid=\(route.uuid.uuidString)",
                    sourceRevisionDescription(route.sourceRevision),
                    metadataDescription(route.metadata)
                ].filter { !$0.isEmpty }.joined(separator: ";")
            ))
            for try await location in HKWorkoutRouteQueryDescriptor(route).results(for: store) {
                try Task.checkCancellation()
                records.append(WorkoutHealthRecord(
                    kind: .routePoint,
                    metric: "workout_route",
                    startDate: location.timestamp,
                    endDate: nil,
                    value: nil,
                    minimum: nil,
                    maximum: nil,
                    unit: "degrees/meters",
                    sourceName: route.sourceRevision.source.name,
                    sourceBundleIdentifier: route.sourceRevision.source.bundleIdentifier,
                    device: deviceDescription(route.device).isEmpty
                        ? device
                        : deviceDescription(route.device),
                    details: [
                        "latitude=\(location.coordinate.latitude)",
                        "longitude=\(location.coordinate.longitude)",
                        "altitude_m=\(location.altitude)",
                        "horizontal_accuracy_m=\(location.horizontalAccuracy)",
                        "vertical_accuracy_m=\(location.verticalAccuracy)",
                        "speed_mps=\(location.speed)",
                        "speed_accuracy_mps=\(location.speedAccuracy)",
                        "course_degrees=\(location.course)",
                        "course_accuracy_degrees=\(location.courseAccuracy)",
                        "floor=\(location.floor.map { String($0.level) } ?? "")",
                        "simulated=\(location.sourceInformation?.isSimulatedBySoftware.description ?? "")",
                        "accessory=\(location.sourceInformation?.isProducedByAccessory.description ?? "")"
                    ].joined(separator: ";")
                ))
            }
        }
        return records
    }

    private func metadataDescription(_ metadata: [String: Any]?) -> String {
        (metadata ?? [:]).keys.sorted().map { key in
            "\(key)=\(metadataValueDescription(metadata?[key]))"
        }.joined(separator: ";")
    }

    private func metadataValueDescription(_ value: Any?) -> String {
        guard let value else { return "" }
        if let date = value as? Date {
            return ISO8601DateFormatter().string(from: date)
        }
        return String(describing: value)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private func deviceDescription(_ device: HKDevice?) -> String {
        guard let device else { return "" }
        return [
            device.name,
            device.manufacturer,
            device.model,
            device.hardwareVersion,
            device.firmwareVersion,
            device.softwareVersion,
            device.localIdentifier,
            device.udiDeviceIdentifier
        ].compactMap { $0 }.joined(separator: " | ")
    }

    private func sourceRevisionDescription(_ revision: HKSourceRevision) -> String {
        let operatingSystem = revision.operatingSystemVersion
        return [
            revision.version.map { "source_version=\($0)" },
            revision.productType.map { "product_type=\($0)" },
            "os_version=\(operatingSystem.majorVersion).\(operatingSystem.minorVersion).\(operatingSystem.patchVersion)"
        ].compactMap { $0 }.joined(separator: ";")
    }

    private func workoutEventName(_ type: HKWorkoutEventType) -> String {
        switch type {
        case .pause: "pause"
        case .resume: "resume"
        case .lap: "lap"
        case .marker: "marker"
        case .motionPaused: "motion_paused"
        case .motionResumed: "motion_resumed"
        case .segment: "segment"
        case .pauseOrResumeRequest: "pause_or_resume_request"
        @unknown default: "unknown_\(type.rawValue)"
        }
    }

    private func optionalNumber(_ value: Double?) -> String {
        value.map { String($0) } ?? ""
    }
}
