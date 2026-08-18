import Foundation

enum HeartRateTimeline {
    static func segmentIndices(
        for elapsedSeconds: [Int],
        maximumGap: Int = 15
    ) -> [Int] {
        guard !elapsedSeconds.isEmpty else { return [] }

        var segment = 0
        var result = [0]
        result.reserveCapacity(elapsedSeconds.count)
        for index in 1..<elapsedSeconds.count {
            if elapsedSeconds[index] - elapsedSeconds[index - 1] > maximumGap {
                segment += 1
            }
            result.append(segment)
        }
        return result
    }
}

struct HeartRateZoneAnalysis: Sendable {
    struct Summary: Identifiable, Sendable, Equatable {
        enum Boundaries: Sendable, Equatable {
            case uniform(minimumBPM: Double?, maximumBPM: Double?)
            case varied
        }

        var id: Int { number }
        let number: Int
        let duration: TimeInterval
        let percentage: Double
        let boundaries: Boundaries
    }

    let summaries: [Summary]
    let workoutCountWithZones: Int
    let workoutCountWithoutZones: Int
    let hasConfigurationVariation: Bool

    static func make(for runs: [OutdoorRun]) -> Self {
        let configurations = runs.compactMap(\.heartRateZoneConfiguration)
        let missingCount = runs.count - configurations.count
        guard !configurations.isEmpty else {
            return Self(
                summaries: [],
                workoutCountWithZones: 0,
                workoutCountWithoutZones: missingCount,
                hasConfigurationVariation: false
            )
        }

        let allZones = configurations.flatMap(\.zones)
        let grandTotal = allZones.reduce(0) { $0 + max(0, $1.duration) }
        let summaries = Dictionary(grouping: allZones, by: \.number)
            .map { number, zones in
                let duration = zones.reduce(0) { $0 + max(0, $1.duration) }
                let boundaryPairs = Set(zones.map {
                    BoundaryPair(minimumBPM: $0.minimumBPM, maximumBPM: $0.maximumBPM)
                })
                let boundaries: Summary.Boundaries
                if boundaryPairs.count == 1, let pair = boundaryPairs.first {
                    boundaries = .uniform(
                        minimumBPM: pair.minimumBPM,
                        maximumBPM: pair.maximumBPM
                    )
                } else {
                    boundaries = .varied
                }
                return Summary(
                    number: number,
                    duration: duration,
                    percentage: grandTotal > 0 ? duration / grandTotal * 100 : 0,
                    boundaries: boundaries
                )
            }
            .sorted { $0.number < $1.number }

        return Self(
            summaries: summaries,
            workoutCountWithZones: configurations.count,
            workoutCountWithoutZones: missingCount,
            hasConfigurationVariation: Set(configurations.map(ConfigurationSignature.init)).count > 1
        )
    }

    private struct BoundaryPair: Hashable {
        let minimumBPM: Double?
        let maximumBPM: Double?
    }

    private struct ConfigurationSignature: Hashable {
        let source: WorkoutHeartRateZoneConfiguration.Source
        let boundaries: [BoundaryPair]

        init(_ configuration: WorkoutHeartRateZoneConfiguration) {
            source = configuration.source
            boundaries = configuration.zones.map {
                BoundaryPair(minimumBPM: $0.minimumBPM, maximumBPM: $0.maximumBPM)
            }
        }
    }
}
