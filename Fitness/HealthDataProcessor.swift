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
        workoutEvents: [HKWorkoutEvent],
        strideLengthSamples: [HKQuantitySample] = []
    ) -> (
        runningEfficiency: RunningEfficiency,
        effectiveRunningHeartRates: [EffectiveRunningHeartRate],
        runningTimeline: [RunningTimelineSample]
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
                cleanedPoints: cleanedPoints
            ),
            effectiveRunningHeartRates: cleanedPoints.map {
                EffectiveRunningHeartRate(
                    elapsedSeconds: Int($0.elapsedSeconds.rounded()),
                    beatsPerMinute: $0.heartRateBPM
                )
            },
            runningTimeline: runningTimeline(
                points: prepared.points,
                workoutStart: workoutStart,
                strideLengthSamples: strideLengthSamples
            )
        )
    }

    private static func runningTimeline(
        points: [RunningPoint],
        workoutStart: Date,
        strideLengthSamples: [HKQuantitySample]
    ) -> [RunningTimelineSample] {
        let strideUnit = HKUnit.meter()
        let strides = unique(strideLengthSamples).sorted { $0.startDate < $1.startDate }
        var strideCursor = 0
        return points.map { point in
            let intervalStart = workoutStart.addingTimeInterval(point.elapsedSeconds)
            let intervalEnd = intervalStart.addingTimeInterval(point.duration)
            while strideCursor < strides.count,
                  strides[strideCursor].endDate <= intervalStart,
                  strides[strideCursor].startDate < intervalStart {
                strideCursor += 1
            }
            var intervalSamples: [HKQuantitySample] = []
            var index = strideCursor
            while index < strides.count, strides[index].startDate < intervalEnd {
                intervalSamples.append(strides[index])
                index += 1
            }
            let weightedStrides = intervalSamples.compactMap { sample -> (Double, TimeInterval)? in
                let overlap = min(sample.endDate, intervalEnd)
                    .timeIntervalSince(max(sample.startDate, intervalStart))
                let value = sample.quantity.doubleValue(for: strideUnit)
                guard overlap > 0, value.isFinite, value > 0 else { return nil }
                return (value, overlap)
            }
            let pointStrides = intervalSamples.filter {
                $0.startDate >= intervalStart && $0.startDate < intervalEnd
            }.map { $0.quantity.doubleValue(for: strideUnit) }
                .filter { $0.isFinite && $0 > 0 }
            let stride = weightedMean(weightedStrides) ?? mean(pointStrides)
            return RunningTimelineSample(
                elapsedSeconds: Int(point.elapsedSeconds.rounded()),
                heartRateBPM: point.heartRateBPM,
                paceSecondsPerKilometer: 1_000 / point.speedMetersPerSecond,
                strideLengthMeters: stride
            )
        }
    }

    private static func runningEfficiency(
        prepared: PreparedRunningPoints,
        cleanedPoints: [RunningPoint]
    ) -> RunningEfficiency {
        guard prepared.hasSufficientCoverage else {
            return .insufficient(
                effectiveDuration: prepared.points.reduce(0) { $0 + $1.duration }
            )
        }

        let analysisPoints = cleanedPoints.filter { $0.elapsedSeconds >= 120 }
        let effectiveDuration = analysisPoints.reduce(0) { $0 + $1.duration }
        guard analysisPoints.count >= 6,
              let averageSpeedMetersPerSecond = weightedMean(
                  analysisPoints.map { ($0.speedMetersPerSecond, $0.duration) }
              ),
              let averageHeartRate = weightedMean(
                  analysisPoints.map { ($0.heartRateBPM, $0.duration) }
              ),
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
        samples: [HKQuantitySample],
        deduplicatedStepCounts: [Double?]
    ) -> [MinuteCadence] {
        let completeMinutes = max(0, Int(workoutEnd.timeIntervalSince(workoutStart) / 60))
        guard completeMinutes > 0 else { return [] }
        let completeWorkoutEnd = workoutStart.addingTimeInterval(Double(completeMinutes) * 60)
        var coverageIntervalsByMinute = Array(
            repeating: [DateInterval](),
            count: completeMinutes
        )

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

                coverageIntervalsByMinute[minute].append(
                    DateInterval(start: overlapStart, end: overlapEnd)
                )
            }
        }

        return coverageIntervalsByMinute.indices.compactMap { minute in
            let measuredSeconds = mergedDuration(coverageIntervalsByMinute[minute])
            guard measuredSeconds > 0,
                  deduplicatedStepCounts.indices.contains(minute),
                  let stepCount = deduplicatedStepCounts[minute],
                  stepCount >= 0 else { return nil }
            return MinuteCadence(
                workoutID: workoutID,
                elapsedMinute: minute + 1,
                stepsPerMinute: stepCount / measuredSeconds * 60,
                coverage: measuredSeconds / 60
            )
        }
    }

    private static func unique(_ samples: [HKQuantitySample]) -> [HKQuantitySample] {
        var identifiers = Set<UUID>()
        return samples.filter { identifiers.insert($0.uuid).inserted }
    }

    private struct RunningPoint {
        let elapsedSeconds: TimeInterval
        let duration: TimeInterval
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
        var heartRateCursor = 0
        var speedCursor = 0
        var distanceCursor = 0

        for interval in 0..<intervalCount {
            let start = workoutStart.addingTimeInterval(Double(interval) * intervalSeconds)
            let end = min(start.addingTimeInterval(intervalSeconds), workoutEnd)
            guard end > start, !overlapsPause(start: start, end: end, pauses: pauses) else { continue }
            eligibleIntervalCount += 1

            let target = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
            let intervalHeartRates = samplesStarting(
                in: heartRates,
                start: start,
                end: end,
                cursor: &heartRateCursor
            )
            let intervalSpeeds = samplesOverlapping(
                in: speeds,
                start: start,
                end: end,
                cursor: &speedCursor
            )
            let intervalDistances = samplesOverlapping(
                in: distances,
                start: start,
                end: end,
                cursor: &distanceCursor
            )
            guard let heartRate = averageHeartRate(
                from: intervalHeartRates,
                allSamples: heartRates,
                target: target,
                unit: heartRateUnit
            ), let speed = averageSpeed(
                from: intervalSpeeds,
                distanceSamples: intervalDistances,
                start: start,
                end: end,
                speedUnit: speedUnit
            ), (60...230).contains(heartRate), (1.0...8.0).contains(speed) else { continue }

            points.append(RunningPoint(
                elapsedSeconds: start.timeIntervalSince(workoutStart),
                duration: end.timeIntervalSince(start),
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
        allSamples: [HKQuantitySample],
        target: Date,
        unit: HKUnit
    ) -> Double? {
        let values = samples
            .map { $0.quantity.doubleValue(for: unit) }
            .filter { (60...230).contains($0) }
        if let value = mean(values) { return value }
        return interpolatedHeartRate(
            at: target,
            samples: allSamples,
            unit: unit,
            maximumGap: 30
        )
    }

    private static func averageSpeed(
        from samples: [HKQuantitySample],
        distanceSamples: [HKQuantitySample],
        start: Date,
        end: Date,
        speedUnit: HKUnit
    ) -> Double? {
        let weightedDirectValues = samples.compactMap { sample -> (Double, TimeInterval)? in
            let overlapStart = max(start, sample.startDate)
            let overlapEnd = min(end, sample.endDate)
            let overlap = overlapEnd.timeIntervalSince(overlapStart)
            let value = sample.quantity.doubleValue(for: speedUnit)
            guard overlap > 0, (1.0...8.0).contains(value) else { return nil }
            return (value, overlap)
        }
        if let direct = weightedMean(weightedDirectValues) { return direct }

        var coverageIntervals: [DateInterval] = []
        let meters = distanceSamples.reduce(into: 0.0) { total, sample in
            let overlapStart = max(start, sample.startDate)
            let overlapEnd = min(end, sample.endDate)
            let sampleDuration = sample.endDate.timeIntervalSince(sample.startDate)
            guard overlapEnd > overlapStart, sampleDuration > 0 else { return }
            let overlap = overlapEnd.timeIntervalSince(overlapStart)
            total += sample.quantity.doubleValue(for: .meter()) * overlap / sampleDuration
            coverageIntervals.append(DateInterval(start: overlapStart, end: overlapEnd))
        }
        let coveredDuration = mergedDuration(coverageIntervals)
        let intervalDuration = end.timeIntervalSince(start)
        guard intervalDuration > 0,
              coveredDuration / intervalDuration >= 0.5,
              meters > 0 else { return nil }
        return meters / coveredDuration
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

    private static func weightedMean(_ values: [(Double, TimeInterval)]) -> Double? {
        let totalWeight = values.reduce(0) { $0 + max(0, $1.1) }
        guard totalWeight > 0 else { return nil }
        return values.reduce(0) { $0 + $1.0 * max(0, $1.1) } / totalWeight
    }

    private static func mergedDuration(_ intervals: [DateInterval]) -> TimeInterval {
        let sorted = intervals.sorted { $0.start < $1.start }
        guard var current = sorted.first else { return 0 }
        var duration: TimeInterval = 0
        for interval in sorted.dropFirst() {
            if interval.start <= current.end {
                current = DateInterval(
                    start: current.start,
                    end: max(current.end, interval.end)
                )
            } else {
                duration += current.duration
                current = interval
            }
        }
        return duration + current.duration
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

    private static func samplesStarting(
        in samples: [HKQuantitySample],
        start: Date,
        end: Date,
        cursor: inout Int
    ) -> [HKQuantitySample] {
        while cursor < samples.count, samples[cursor].startDate < start {
            cursor += 1
        }
        var upper = cursor
        while upper < samples.count, samples[upper].startDate < end {
            upper += 1
        }
        return Array(samples[cursor..<upper])
    }

    private static func samplesOverlapping(
        in samples: [HKQuantitySample],
        start: Date,
        end: Date,
        cursor: inout Int
    ) -> [HKQuantitySample] {
        while cursor < samples.count, samples[cursor].endDate <= start {
            cursor += 1
        }
        var upper = cursor
        while upper < samples.count, samples[upper].startDate < end {
            upper += 1
        }
        return samples[cursor..<upper].filter { $0.endDate > start }
    }
}
