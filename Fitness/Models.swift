import Foundation

struct OutdoorRun: Identifiable, Codable, Sendable {
    let id: UUID
    let startDate: Date
    let endDate: Date
    let duration: TimeInterval
    let distanceKm: Double
    let kilometerSplits: [KilometerSplit]
    let minuteHeartRateData: [MinuteHeartRate]
    let minuteCadenceData: [MinuteCadence]
    let runningEfficiency: RunningEfficiency
    let effectiveRunningHeartRates: [EffectiveRunningHeartRate]
    let runningTimelineData: [RunningTimelineSample]
    let heartRateZoneConfiguration: WorkoutHeartRateZoneConfiguration?
}

struct RunningTimelineSample: Identifiable, Codable, Sendable {
    var id: Int { elapsedSeconds }
    let elapsedSeconds: Int
    let heartRateBPM: Double
    let paceSecondsPerKilometer: Double
    let strideLengthMeters: Double?
}

struct ElevationTimelineSample: Identifiable, Sendable {
    var id: Int { elapsedSeconds }
    let elapsedSeconds: Int
    let meters: Double
}

/// Data read on demand for a user-selected workout export. Keeping this out of
/// `OutdoorRun` prevents large HealthKit sample and route collections from
/// increasing the processed-run cache or normal screen loading cost.
struct WorkoutHealthExport: Sendable {
    let workoutID: UUID
    let records: [WorkoutHealthRecord]
}

struct WorkoutHealthRecord: Sendable {
    enum Kind: String, Sendable {
        case workout
        case metadata
        case event
        case activity
        case statistic
        case quantitySample = "quantity_sample"
        case heartRateZone = "heart_rate_zone"
        case routePoint = "route_point"
    }

    let kind: Kind
    let metric: String
    let startDate: Date?
    let endDate: Date?
    let value: Double?
    let minimum: Double?
    let maximum: Double?
    let unit: String
    let sourceName: String
    let sourceBundleIdentifier: String
    let device: String
    let details: String
}

struct WorkoutHeartRateZoneConfiguration: Codable, Sendable, Equatable {
    enum Source: String, Codable, Sendable {
        case systemAutomatic
        case userCustom
        case appCustom
        case unknown
    }

    let source: Source
    let zones: [WorkoutHeartRateZone]

    var zoneCount: Int { zones.count }
    var totalDuration: TimeInterval {
        zones.reduce(0) { $0 + max(0, $1.duration) }
    }
}

struct WorkoutHeartRateZone: Identifiable, Codable, Sendable, Equatable {
    var id: Int { number }
    let number: Int
    let duration: TimeInterval
    let minimumBPM: Double?
    let maximumBPM: Double?
}

struct RunningEfficiency: Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case available
        case insufficientData
    }

    let status: Status
    let value: Double?
    let averageSpeedKilometersPerHour: Double?
    let averageHeartRateBPM: Double?
    let effectiveDuration: TimeInterval

    static func insufficient(effectiveDuration: TimeInterval = 0) -> Self {
        Self(
            status: .insufficientData,
            value: nil,
            averageSpeedKilometersPerHour: nil,
            averageHeartRateBPM: nil,
            effectiveDuration: effectiveDuration
        )
    }
}

struct EffectiveRunningHeartRate: Codable, Sendable {
    let elapsedSeconds: Int
    let beatsPerMinute: Double
}

struct KilometerSplit: Identifiable, Codable, Sendable {
    var id: String { "\(workoutID.uuidString)-\(kilometerIndex)" }
    let workoutID: UUID
    let kilometerIndex: Int
    let startTime: Date
    let endTime: Date
    let paceSecondsPerKm: Double
}

struct MinuteHeartRate: Identifiable, Codable, Sendable {
    var id: String { "\(workoutID.uuidString)-\(elapsedSeconds)" }
    let workoutID: UUID
    let elapsedSeconds: Int
    let minimumBPM: Double
    let maximumBPM: Double
    let averageBPM: Double
}

struct MinuteCadence: Identifiable, Codable, Sendable {
    var id: String { "\(workoutID.uuidString)-\(elapsedMinute)" }
    let workoutID: UUID
    let elapsedMinute: Int
    let stepsPerMinute: Double
    let coverage: Double
}

extension Array where Element == OutdoorRun {
    var splits: [KilometerSplit] { flatMap(\.kilometerSplits) }
}
