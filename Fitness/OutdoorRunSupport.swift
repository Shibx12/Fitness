import Foundation
import SwiftUI
import UIKit

struct ExportArtifact: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

enum OutdoorRunCSVExporter {
    static func export(
        _ runs: [OutdoorRun],
        healthData: [WorkoutHealthExport] = []
    ) throws -> URL {
        let header = [
            "workout_id", "start_date", "end_date", "distance_km",
            "duration_seconds", "metric", "interval_index", "elapsed_seconds",
            "value", "minimum", "maximum", "unit", "status",
            "average_speed_kmh", "average_heart_rate_bpm", "record_kind",
            "record_start_date", "record_end_date", "source_name",
            "source_bundle_identifier", "device", "details"
        ]
        let iso8601 = ISO8601DateFormatter()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Outdoor-Runs-\(UUID().uuidString).csv")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try write("\u{FEFF}\(csvRow(header))\r\n", to: handle)

            for run in runs.sorted(by: { $0.startDate < $1.startDate }) {
                try Task.checkCancellation()
                try write(try runRows(run, iso8601: iso8601), to: handle)
            }
            let runOrder = Dictionary(
                uniqueKeysWithValues: runs.sorted(by: { $0.startDate < $1.startDate })
                    .enumerated()
                    .map { ($0.element.id, $0.offset) }
            )
            for workout in healthData.sorted(by: {
                runOrder[$0.workoutID, default: .max]
                    < runOrder[$1.workoutID, default: .max]
            }) {
                try Task.checkCancellation()
                try write(try healthDataRows(workout, iso8601: iso8601), to: handle)
            }

            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: url.path
            )
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private static func runRows(
        _ run: OutdoorRun,
        iso8601: ISO8601DateFormatter
    ) throws -> String {
        var rows: [String] = []
            let common = [
                run.id.uuidString,
                iso8601.string(from: run.startDate),
                iso8601.string(from: run.endDate),
                decimal(run.distanceKm, places: 3),
                decimal(run.duration, places: 1)
            ]
            rows.append(csvRow(common + ["workout", "", "", "", "", "", "", "", "", ""] + emptyRawColumns))

            for split in run.kilometerSplits {
                try Task.checkCancellation()
                let elapsed = split.endTime.timeIntervalSince(run.startDate)
                rows.append(csvRow(common + [
                    "pace", String(split.kilometerIndex), decimal(elapsed, places: 1),
                    decimal(split.paceSecondsPerKm, places: 2), "", "", "sec/km", "", "", ""
                ] + emptyRawColumns))
            }

            for heartRate in run.minuteHeartRateData {
                try Task.checkCancellation()
                rows.append(csvRow(common + [
                    "heart_rate", String((heartRate.elapsedSeconds / 10) + 1),
                    String(heartRate.elapsedSeconds), decimal(heartRate.averageBPM, places: 2),
                    decimal(heartRate.minimumBPM, places: 2),
                    decimal(heartRate.maximumBPM, places: 2), "bpm", "", "", ""
                ] + emptyRawColumns))
            }

            for (index, heartRate) in run.effectiveRunningHeartRates.enumerated() {
                try Task.checkCancellation()
                rows.append(csvRow(common + [
                    "effective_running_heart_rate", String(index + 1),
                    String(heartRate.elapsedSeconds),
                    decimal(heartRate.beatsPerMinute, places: 2), "", "", "bpm", "", "", ""
                ] + emptyRawColumns))
            }

            for zone in run.heartRateZoneConfiguration?.zones ?? [] {
                try Task.checkCancellation()
                rows.append(csvRow(common + [
                    "heart_rate_zone", String(zone.number), "",
                    decimal(zone.duration, places: 1),
                    optionalDecimal(zone.minimumBPM, places: 1),
                    optionalDecimal(zone.maximumBPM, places: 1),
                    "seconds", "apple_workout_zone", "", ""
                ] + emptyRawColumns))
            }

            for cadence in run.minuteCadenceData {
                try Task.checkCancellation()
                rows.append(csvRow(common + [
                    "cadence", String(cadence.elapsedMinute),
                    String((cadence.elapsedMinute - 1) * 60),
                    decimal(cadence.stepsPerMinute, places: 2), "", "", "spm",
                    "coverage=\(decimal(cadence.coverage, places: 3))", "", ""
                ] + emptyRawColumns))
            }

            let efficiency = run.runningEfficiency
            rows.append(csvRow(common + [
                "running_efficiency", "", decimal(efficiency.effectiveDuration, places: 1),
                optionalDecimal(efficiency.value, places: 7), "", "", "km/h/bpm",
                efficiency.status.rawValue,
                optionalDecimal(efficiency.averageSpeedKilometersPerHour, places: 3),
                optionalDecimal(efficiency.averageHeartRateBPM, places: 2)
            ] + emptyRawColumns))
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    private static let emptyRawColumns = Array(repeating: "", count: 7)

    private static func healthDataRows(
        _ workout: WorkoutHealthExport,
        iso8601: ISO8601DateFormatter
    ) throws -> String {
        var rows: [String] = []
        rows.reserveCapacity(workout.records.count)
        for record in workout.records {
            try Task.checkCancellation()
            rows.append(csvRow([
                workout.workoutID.uuidString,
                "", "", "", "",
                record.metric,
                "", "",
                optionalDecimal(record.value, places: 8),
                optionalDecimal(record.minimum, places: 8),
                optionalDecimal(record.maximum, places: 8),
                record.unit,
                "healthkit_raw",
                "", "",
                record.kind.rawValue,
                record.startDate.map(iso8601.string(from:)) ?? "",
                record.endDate.map(iso8601.string(from:)) ?? "",
                record.sourceName,
                record.sourceBundleIdentifier,
                record.device,
                record.details
            ]))
        }
        guard !rows.isEmpty else { return "" }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    private static func write(_ string: String, to handle: FileHandle) throws {
        try handle.write(contentsOf: Data(string.utf8))
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
