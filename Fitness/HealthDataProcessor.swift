import Foundation
import HealthKit

enum HealthDataProcessor {
    static func kilometerSplits(
        workoutID: UUID,
        workoutStart: Date,
        workoutEnd: Date,
        samples: [HKQuantitySample]
    ) -> [KilometerSplit] {
        let unit = HKUnit.meter()
        let segments = unique(samples)
            .sorted { $0.startDate < $1.startDate }
            .compactMap { sample -> (Date, Date, Double)? in
                let start = max(sample.startDate, workoutStart)
                let end = min(sample.endDate, workoutEnd)
                guard end >= start else { return nil }
                let originalDuration = sample.endDate.timeIntervalSince(sample.startDate)
                let overlap = end.timeIntervalSince(start)
                let ratio = originalDuration > 0 ? overlap / originalDuration : 1
                let meters = sample.quantity.doubleValue(for: unit) * ratio
                return meters > 0 ? (start, end, meters) : nil
            }

        var result: [KilometerSplit] = []
        var cumulativeMeters = 0.0
        var previousBoundary = workoutStart
        var nextBoundaryMeters = 1_000.0

        for segment in segments {
            let before = cumulativeMeters
            let after = before + segment.2

            // Distance is assumed to accrue evenly within each HealthKit sample;
            // this interpolates the timestamp when an exact kilometer is crossed.
            while nextBoundaryMeters <= after {
                let fraction = (nextBoundaryMeters - before) / segment.2
                let boundary = segment.0.addingTimeInterval(
                    segment.1.timeIntervalSince(segment.0) * fraction
                )
                let duration = boundary.timeIntervalSince(previousBoundary)
                if duration > 0 {
                    result.append(KilometerSplit(
                        workoutID: workoutID,
                        kilometerIndex: result.count + 1,
                        startTime: previousBoundary,
                        endTime: boundary,
                        paceSecondsPerKm: duration
                    ))
                }
                previousBoundary = boundary
                nextBoundaryMeters += 1_000
            }
            cumulativeMeters = after
        }
        return result
    }

    static func minuteHeartRate(
        workoutID: UUID,
        workoutStart: Date,
        workoutEnd: Date,
        samples: [HKQuantitySample]
    ) -> [MinuteHeartRate] {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let validSamples = unique(samples)
            .filter { sample in
                sample.startDate >= workoutStart
                    && sample.startDate < workoutEnd
                    && sample.quantity.doubleValue(for: bpm) > 0
            }
            .sorted { $0.startDate < $1.startDate }
        guard !validSamples.isEmpty else { return [] }

        let intervalSeconds: TimeInterval = 10
        let intervalCount = Int(ceil(workoutEnd.timeIntervalSince(workoutStart) / intervalSeconds))
        let valuesByInterval = Dictionary(grouping: validSamples) { sample in
            Int(sample.startDate.timeIntervalSince(workoutStart) / intervalSeconds)
        }.mapValues { intervalSamples in
            intervalSamples.map { $0.quantity.doubleValue(for: bpm) }
        }
        var result: [MinuteHeartRate] = []

        for interval in 0..<intervalCount {
            let intervalStart = workoutStart.addingTimeInterval(Double(interval) * intervalSeconds)
            let intervalEnd = min(intervalStart.addingTimeInterval(intervalSeconds), workoutEnd)
            let values = valuesByInterval[interval] ?? []

            if let minimum = values.min(), let maximum = values.max() {
                result.append(MinuteHeartRate(
                    workoutID: workoutID,
                    elapsedSeconds: interval * Int(intervalSeconds),
                    minimumBPM: minimum,
                    maximumBPM: maximum,
                    averageBPM: values.reduce(0, +) / Double(values.count)
                ))
                continue
            }

            // Apple Watch can leave sampling holes between ten-second intervals.
            // Interpolate only inside two real observations; never extrapolate before
            // the first or after the last measured heart rate.
            let target = intervalStart.addingTimeInterval(intervalEnd.timeIntervalSince(intervalStart) / 2)
            guard let interpolated = interpolatedHeartRate(
                at: target,
                samples: validSamples,
                unit: bpm,
                maximumGap: 30
            ) else { continue }

            result.append(MinuteHeartRate(
                workoutID: workoutID,
                elapsedSeconds: interval * Int(intervalSeconds),
                minimumBPM: interpolated,
                maximumBPM: interpolated,
                averageBPM: interpolated
            ))
        }
        return result
    }

    static func runningMetrics(
        workoutStart: Date,
        workoutEnd: Date,
        heartRateSamples: [HKQuantitySample],
        speedSamples: [HKQuantitySample],
        distanceSamples: [HKQuantitySample],
        workoutEvents: [HKWorkoutEvent]
    ) -> (
        runningEfficiency: RunningEfficiency,
        effectiveRunningHeartRates: [Double]
    ) {
        let intervalSeconds: TimeInterval = 10
        let prepared = preparedRunningPoints(
            workoutStart: workoutStart,
            workoutEnd: workoutEnd,
            heartRateSamples: heartRateSamples,
            speedSamples: speedSamples,
            distanceSamples: distanceSamples,
            workoutEvents: workoutEvents,
            intervalSeconds: intervalSeconds
        )
        let cleanedPoints = prepared.hasSufficientCoverage
            ? removeRunningOutliers(prepared.points)
            : []
        return (
            runningEfficiency: runningEfficiency(
                prepared: prepared,
                cleanedPoints: cleanedPoints,
                intervalSeconds: intervalSeconds
            ),
            effectiveRunningHeartRates: cleanedPoints.map(\.heartRateBPM)
        )
    }

    private static func runningEfficiency(
        prepared: PreparedRunningPoints,
        cleanedPoints: [RunningPoint],
        intervalSeconds: TimeInterval
    ) -> RunningEfficiency {
        guard prepared.hasSufficientCoverage else {
            return .insufficient(effectiveDuration: Double(prepared.points.count) * intervalSeconds)
        }

        let warmupIntervalCount = Int(120 / intervalSeconds)
        let analysisPoints = Array(cleanedPoints.dropFirst(warmupIntervalCount))
        let effectiveDuration = Double(analysisPoints.count) * intervalSeconds
        guard analysisPoints.count >= 6,
              let averageSpeedMetersPerSecond = mean(analysisPoints.map(\.speedMetersPerSecond)),
              let averageHeartRate = mean(analysisPoints.map(\.heartRateBPM)),
              averageSpeedMetersPerSecond > 0,
              averageHeartRate > 0 else {
            return .insufficient(effectiveDuration: effectiveDuration)
        }

        let averageSpeedKilometersPerHour = averageSpeedMetersPerSecond * 3.6
        let efficiency = averageSpeedKilometersPerHour / averageHeartRate
        guard efficiency.isFinite else {
            return .insufficient(effectiveDuration: effectiveDuration)
        }

        return RunningEfficiency(
            status: .available,
            value: efficiency,
            averageSpeedKilometersPerHour: averageSpeedKilometersPerHour,
            averageHeartRateBPM: averageHeartRate,
            effectiveDuration: effectiveDuration
        )
    }

    static func minuteCadence(
        workoutID: UUID,
        workoutStart: Date,
        workoutEnd: Date,
        samples: [HKQuantitySample]
    ) -> [MinuteCadence] {
        let completeMinutes = max(0, Int(workoutEnd.timeIntervalSince(workoutStart) / 60))
        guard completeMinutes > 0 else { return [] }
        let completeWorkoutEnd = workoutStart.addingTimeInterval(Double(completeMinutes) * 60)
        var stepsByMinute = Array(repeating: 0.0, count: completeMinutes)
        var measuredMinutes = Set<Int>()

        for sample in unique(samples) {
            let sampleDuration = sample.endDate.timeIntervalSince(sample.startDate)
            guard sampleDuration > 0 else { continue }
            let sampleStart = max(sample.startDate, workoutStart)
            let sampleEnd = min(sample.endDate, completeWorkoutEnd)
            guard sampleEnd > sampleStart else { continue }

            let firstMinute = max(0, Int(sampleStart.timeIntervalSince(workoutStart) / 60))
            let lastMinute = min(
                completeMinutes - 1,
                Int(ceil(sampleEnd.timeIntervalSince(workoutStart) / 60)) - 1
            )
            guard firstMinute <= lastMinute else { continue }

            for minute in firstMinute...lastMinute {
                let bucketStart = workoutStart.addingTimeInterval(Double(minute) * 60)
                let bucketEnd = bucketStart.addingTimeInterval(60)
                let overlapStart = max(bucketStart, sample.startDate)
                let overlapEnd = min(bucketEnd, sample.endDate)
                guard overlapEnd > overlapStart else { continue }

                let overlapRatio = overlapEnd.timeIntervalSince(overlapStart) / sampleDuration
                stepsByMinute[minute] += sample.quantity.doubleValue(for: .count()) * overlapRatio
                measuredMinutes.insert(minute)
            }
        }

        return measuredMinutes.sorted().map { minute in
            MinuteCadence(
                workoutID: workoutID,
                elapsedMinute: minute + 1,
                stepsPerMinute: stepsByMinute[minute]
            )
        }
    }

    private static func unique(_ samples: [HKQuantitySample]) -> [HKQuantitySample] {
        var identifiers = Set<UUID>()
        return samples.filter { identifiers.insert($0.uuid).inserted }
    }

    private struct RunningPoint {
        let speedMetersPerSecond: Double
        let heartRateBPM: Double
    }

    private struct PreparedRunningPoints {
        let points: [RunningPoint]
        let eligibleIntervalCount: Int

        var hasSufficientCoverage: Bool {
            eligibleIntervalCount > 0
                && Double(points.count) / Double(eligibleIntervalCount) >= 0.70
        }
    }

    private static func preparedRunningPoints(
        workoutStart: Date,
        workoutEnd: Date,
        heartRateSamples: [HKQuantitySample],
        speedSamples: [HKQuantitySample],
        distanceSamples: [HKQuantitySample],
        workoutEvents: [HKWorkoutEvent],
        intervalSeconds: TimeInterval
    ) -> PreparedRunningPoints {
        let heartRateUnit = HKUnit.count().unitDivided(by: .minute())
        let speedUnit = HKUnit.meter().unitDivided(by: .second())
        let heartRates = unique(heartRateSamples).sorted { $0.startDate < $1.startDate }
        let speeds = unique(speedSamples).sorted { $0.startDate < $1.startDate }
        let distances = unique(distanceSamples).sorted { $0.startDate < $1.startDate }
        let pauses = pauseIntervals(
            events: workoutEvents,
            workoutStart: workoutStart,
            workoutEnd: workoutEnd
        )
        let intervalCount = Int(ceil(workoutEnd.timeIntervalSince(workoutStart) / intervalSeconds))
        guard intervalCount > 0, !heartRates.isEmpty else {
            return PreparedRunningPoints(points: [], eligibleIntervalCount: 0)
        }

        var eligibleIntervalCount = 0
        var points: [RunningPoint] = []

        for interval in 0..<intervalCount {
            let start = workoutStart.addingTimeInterval(Double(interval) * intervalSeconds)
            let end = min(start.addingTimeInterval(intervalSeconds), workoutEnd)
            guard end > start, !overlapsPause(start: start, end: end, pauses: pauses) else { continue }
            eligibleIntervalCount += 1

            let target = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
            guard let heartRate = averageHeartRate(
                from: heartRates,
                start: start,
                end: end,
                target: target,
                unit: heartRateUnit
            ), let speed = averageSpeed(
                from: speeds,
                distanceSamples: distances,
                start: start,
                end: end,
                speedUnit: speedUnit
            ), (60...230).contains(heartRate), (1.0...8.0).contains(speed) else { continue }

            points.append(RunningPoint(
                speedMetersPerSecond: speed,
                heartRateBPM: heartRate
            ))
        }

        return PreparedRunningPoints(
            points: points,
            eligibleIntervalCount: eligibleIntervalCount
        )
    }

    private static func averageHeartRate(
        from samples: [HKQuantitySample],
        start: Date,
        end: Date,
        target: Date,
        unit: HKUnit
    ) -> Double? {
        let values = samples
            .filter { $0.startDate >= start && $0.startDate < end }
            .map { $0.quantity.doubleValue(for: unit) }
            .filter { (60...230).contains($0) }
        if let value = mean(values) { return value }
        return interpolatedHeartRate(at: target, samples: samples, unit: unit, maximumGap: 30)
    }

    private static func averageSpeed(
        from samples: [HKQuantitySample],
        distanceSamples: [HKQuantitySample],
        start: Date,
        end: Date,
        speedUnit: HKUnit
    ) -> Double? {
        let directValues = samples
            .filter { $0.endDate > start && $0.startDate < end }
            .map { $0.quantity.doubleValue(for: speedUnit) }
            .filter { (1.0...8.0).contains($0) }
        if let direct = mean(directValues) { return direct }

        let meters = distanceSamples.reduce(into: 0.0) { total, sample in
            let overlapStart = max(start, sample.startDate)
            let overlapEnd = min(end, sample.endDate)
            let sampleDuration = sample.endDate.timeIntervalSince(sample.startDate)
            guard overlapEnd > overlapStart, sampleDuration > 0 else { return }
            let overlap = overlapEnd.timeIntervalSince(overlapStart)
            total += sample.quantity.doubleValue(for: .meter()) * overlap / sampleDuration
        }
        let duration = end.timeIntervalSince(start)
        guard duration > 0, meters > 0 else { return nil }
        return meters / duration
    }

    private static func pauseIntervals(
        events: [HKWorkoutEvent],
        workoutStart: Date,
        workoutEnd: Date
    ) -> [DateInterval] {
        var pausedAt: Date?
        var intervals: [DateInterval] = []

        for event in events.sorted(by: { $0.dateInterval.start < $1.dateInterval.start }) {
            switch event.type {
            case .pause, .motionPaused:
                let start = max(event.dateInterval.start, workoutStart)
                let end = min(event.dateInterval.end, workoutEnd)
                if end > start {
                    intervals.append(DateInterval(start: start, end: end))
                    pausedAt = nil
                } else if pausedAt == nil {
                    pausedAt = start
                }
            case .resume, .motionResumed:
                guard let start = pausedAt else { continue }
                let end = min(event.dateInterval.start, workoutEnd)
                if end > start { intervals.append(DateInterval(start: start, end: end)) }
                pausedAt = nil
            default:
                continue
            }
        }

        if let start = pausedAt, workoutEnd > start {
            intervals.append(DateInterval(start: start, end: workoutEnd))
        }
        return intervals
    }

    private static func overlapsPause(start: Date, end: Date, pauses: [DateInterval]) -> Bool {
        pauses.contains { $0.start < end && $0.end > start }
    }

    private static func removeRunningOutliers(_ points: [RunningPoint]) -> [RunningPoint] {
        guard let medianSpeed = median(points.map(\.speedMetersPerSecond)),
              let medianHeartRate = median(points.map(\.heartRateBPM)) else { return [] }
        let speedMAD = median(points.map { abs($0.speedMetersPerSecond - medianSpeed) }) ?? 0
        let heartRateMAD = median(points.map { abs($0.heartRateBPM - medianHeartRate) }) ?? 0
        let speedTolerance = max(medianSpeed * 0.35, speedMAD * 4)
        let heartRateTolerance = max(30, heartRateMAD * 4)

        return points.filter {
            abs($0.speedMetersPerSecond - medianSpeed) <= speedTolerance
                && abs($0.heartRateBPM - medianHeartRate) <= heartRateTolerance
        }
    }

    private static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func interpolatedHeartRate(
        at target: Date,
        samples: [HKQuantitySample],
        unit: HKUnit,
        maximumGap: TimeInterval
    ) -> Double? {
        let nextIndex = firstSampleIndex(atOrAfter: target, in: samples)
        let previousIndex = nextIndex < samples.count && samples[nextIndex].startDate == target
            ? nextIndex
            : nextIndex - 1
        guard samples.indices.contains(previousIndex), samples.indices.contains(nextIndex) else {
            return nil
        }
        let previous = samples[previousIndex]
        let next = samples[nextIndex]
        guard previous.uuid != next.uuid else { return nil }

        let interval = next.startDate.timeIntervalSince(previous.startDate)
        // Never draw a synthetic slope across a long Watch sampling gap. Thirty
        // seconds is enough to bridge ordinary missed readings while preserving
        // genuine pauses or missing tail data as an empty interval.
        guard interval > 0, interval <= maximumGap else { return nil }
        let fraction = target.timeIntervalSince(previous.startDate) / interval
        let previousBPM = previous.quantity.doubleValue(for: unit)
        let nextBPM = next.quantity.doubleValue(for: unit)
        return previousBPM + ((nextBPM - previousBPM) * fraction)
    }

    private static func firstSampleIndex(
        atOrAfter target: Date,
        in samples: [HKQuantitySample]
    ) -> Int {
        var lower = 0
        var upper = samples.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if samples[middle].startDate < target {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}
