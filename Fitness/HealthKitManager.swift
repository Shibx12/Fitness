import Foundation
import HealthKit

final class HealthKitManager {
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

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw Error.unavailable }
        guard let distanceType, let heartRateType, let stepType else { throw Error.missingTypes }
        var readTypes: Set<HKObjectType> = [workoutType, distanceType, heartRateType, stepType]
        if let runningSpeedType { readTypes.insert(runningSpeedType) }
        try await store.requestAuthorization(
            toShare: [],
            read: readTypes
        )
    }

    func loadOutdoorRuns() async throws -> [OutdoorRun] {
        guard let distanceType, let heartRateType, let stepType else { throw Error.missingTypes }
        let running = HKQuery.predicateForWorkouts(with: .running)
        let workouts = try await samples(
            type: workoutType,
            predicate: running,
            sort: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        ).compactMap { $0 as? HKWorkout }

        var runs: [OutdoorRun] = []
        for workout in workouts where isOutdoor(workout) {
            async let distance = quantitySamples(type: distanceType, workout: workout)
            async let heartRate = quantitySamples(type: heartRateType, workout: workout)
            async let speed = optionalQuantitySamples(type: runningSpeedType, workout: workout)
            async let steps = quantitySamples(type: stepType, workout: workout)

            let distanceSamples = try await distance
            let heartRateSamples = try await heartRate
            let speedSamples = try await speed
            let stepSamples = try await steps
            let id = workout.uuid
            let runningMetrics = HealthDataProcessor.runningMetrics(
                workoutStart: workout.startDate,
                workoutEnd: workout.endDate,
                heartRateSamples: heartRateSamples,
                speedSamples: speedSamples,
                distanceSamples: distanceSamples,
                workoutEvents: workout.workoutEvents ?? []
            )
            runs.append(OutdoorRun(
                id: id,
                startDate: workout.startDate,
                endDate: workout.endDate,
                duration: workout.duration,
                distanceKm: workout.statistics(for: distanceType)?.sumQuantity()?.doubleValue(for: .meterUnit(with: .kilo))
                    ?? distanceSamples.reduce(0) { $0 + $1.quantity.doubleValue(for: .meterUnit(with: .kilo)) },
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
                    samples: stepSamples
                ),
                runningEfficiency: runningMetrics.runningEfficiency,
                effectiveRunningHeartRates: runningMetrics.effectiveRunningHeartRates,
                heartRateZones: heartRateZones(for: workout, heartRateType: heartRateType)
            ))
        }
        return runs
    }

    private func heartRateZones(
        for workout: HKWorkout,
        heartRateType: HKQuantityType
    ) -> [WorkoutHeartRateZone] {
        guard let group = workout.zoneGroupsByType?[heartRateType] else { return [] }
        let bpm = HKUnit.count().unitDivided(by: .minute())

        return group.zoneDurations
            .map { zoneDuration in
                WorkoutHeartRateZone(
                    index: zoneDuration.zone.index,
                    duration: zoneDuration.duration,
                    minimumBPM: zoneDuration.zone.minimum?.doubleValue(for: bpm),
                    maximumBPM: zoneDuration.zone.maximum?.doubleValue(for: bpm)
                )
            }
            .sorted { $0.index < $1.index }
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
        return try await samples(type: type, predicate: predicate).compactMap { $0 as? HKQuantitySample }
    }

    private func optionalQuantitySamples(
        type: HKQuantityType?,
        workout: HKWorkout
    ) async throws -> [HKQuantitySample] {
        guard let type else { return [] }
        return try await quantitySamples(type: type, workout: workout)
    }

    private func samples(
        type: HKSampleType,
        predicate: NSPredicate?,
        sort: [NSSortDescriptor]? = nil
    ) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKSample], Swift.Error>) in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: sort
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            store.execute(query)
        }
    }
}
