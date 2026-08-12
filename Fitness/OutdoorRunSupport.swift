import Foundation

enum OutdoorRunCSVExporter {
    static func export(_ runs: [OutdoorRun]) throws -> URL {
        let header = [
            "workout_id", "start_date", "end_date", "distance_km",
            "duration_seconds", "metric", "interval_index", "elapsed_seconds",
            "value", "minimum", "maximum", "unit", "status",
            "average_speed_kmh", "average_heart_rate_bpm"
        ]
        var rows = [csvRow(header)]
        let iso8601 = ISO8601DateFormatter()

        for run in runs.sorted(by: { $0.startDate < $1.startDate }) {
            let common = [
                run.id.uuidString,
                iso8601.string(from: run.startDate),
                iso8601.string(from: run.endDate),
                decimal(run.distanceKm, places: 3),
                decimal(run.duration, places: 1)
            ]
            rows.append(csvRow(common + ["workout", "", "", "", "", "", "", "", "", ""]))

            for split in run.kilometerSplits {
                let elapsed = split.endTime.timeIntervalSince(run.startDate)
                rows.append(csvRow(common + [
                    "pace", String(split.kilometerIndex), decimal(elapsed, places: 1),
                    decimal(split.paceSecondsPerKm, places: 2), "", "", "sec/km", "", "", ""
                ]))
            }

            for heartRate in run.minuteHeartRateData {
                rows.append(csvRow(common + [
                    "heart_rate", String((heartRate.elapsedSeconds / 10) + 1),
                    String(heartRate.elapsedSeconds), decimal(heartRate.averageBPM, places: 2),
                    decimal(heartRate.minimumBPM, places: 2),
                    decimal(heartRate.maximumBPM, places: 2), "bpm", "", "", ""
                ]))
            }

            for (index, heartRate) in run.effectiveRunningHeartRates.enumerated() {
                rows.append(csvRow(common + [
                    "effective_running_heart_rate", String(index + 1), String(index * 10),
                    decimal(heartRate, places: 2), "", "", "bpm", "", "", ""
                ]))
            }

            for zone in run.heartRateZones {
                rows.append(csvRow(common + [
                    "heart_rate_zone", String(zone.index + 1), "",
                    decimal(zone.duration, places: 1),
                    optionalDecimal(zone.minimumBPM, places: 1),
                    optionalDecimal(zone.maximumBPM, places: 1),
                    "seconds", "apple_workout_zone", "", ""
                ]))
            }

            for cadence in run.minuteCadenceData {
                rows.append(csvRow(common + [
                    "cadence", String(cadence.elapsedMinute),
                    String((cadence.elapsedMinute - 1) * 60),
                    decimal(cadence.stepsPerMinute, places: 2), "", "", "spm", "", "", ""
                ]))
            }

            let efficiency = run.runningEfficiency
            rows.append(csvRow(common + [
                "running_efficiency", "", decimal(efficiency.effectiveDuration, places: 1),
                optionalDecimal(efficiency.value, places: 7), "", "", "km/h/bpm",
                efficiency.status.rawValue,
                optionalDecimal(efficiency.averageSpeedKilometersPerHour, places: 3),
                optionalDecimal(efficiency.averageHeartRateBPM, places: 2)
            ]))
        }

        let content = "\u{FEFF}" + rows.joined(separator: "\r\n") + "\r\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Outdoor-Runs-\(UUID().uuidString).csv")
        try Data(content.utf8).write(to: url, options: .atomic)
        return url
    }

    private static func csvRow(_ fields: [String]) -> String {
        fields.map(csvField).joined(separator: ",")
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func decimal(_ value: Double, places: Int) -> String {
        String(
            format: "%.\(places)f",
            locale: Locale(identifier: "en_US_POSIX"),
            value
        )
    }

    private static func optionalDecimal(_ value: Double?, places: Int) -> String {
        value.map { decimal($0, places: places) } ?? ""
    }
}

enum RunSelectionPreferences {
    private struct Snapshot: Codable {
        let selectedRunIDs: Set<UUID>
        let availableRunIDs: Set<UUID>
    }

    private static let snapshotKey = "outdoorRunSelectionSnapshot"

    static func loadSelectedRunIDs(availableRunIDs: Set<UUID>) -> Set<UUID> {
        guard let data = UserDefaults.standard.data(forKey: snapshotKey),
              let snapshot = try? PropertyListDecoder().decode(Snapshot.self, from: data) else {
            return availableRunIDs
        }

        let newlyAvailableRunIDs = availableRunIDs.subtracting(snapshot.availableRunIDs)
        return snapshot.selectedRunIDs
            .intersection(availableRunIDs)
            .union(newlyAvailableRunIDs)
    }

    static func saveSelectedRunIDs(
        _ selectedRunIDs: Set<UUID>,
        availableRunIDs: Set<UUID>
    ) {
        let snapshot = Snapshot(
            selectedRunIDs: selectedRunIDs.intersection(availableRunIDs),
            availableRunIDs: availableRunIDs
        )
        guard let data = try? PropertyListEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: snapshotKey)
    }
}
