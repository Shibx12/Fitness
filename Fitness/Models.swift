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
    let effectiveRunningHeartRates: [Double]
    let heartRateZones: [WorkoutHeartRateZone]
}

struct WorkoutHeartRateZone: Identifiable, Codable, Sendable {
    var id: Int { index }
    let index: Int
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
}

extension Array where Element == OutdoorRun {
    var splits: [KilometerSplit] { flatMap(\.kilometerSplits) }
    var cadence: [MinuteCadence] { flatMap(\.minuteCadenceData) }
}
