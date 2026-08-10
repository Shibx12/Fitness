import SwiftUI

struct OutdoorRunAnalyticsView: View {
    let runs: [OutdoorRun]
    @State private var includedRunIDs: Set<UUID>
    @State private var showsRunFilter = false

    init(runs: [OutdoorRun]) {
        self.runs = runs
        let allRunIDs = Set(runs.map(\.id))
        let excludedRunIDs = RunSelectionPreferences.loadExcludedRunIDs()
        _includedRunIDs = State(initialValue: allRunIDs.subtracting(excludedRunIDs))
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                WeeklyRunSummaryView(runs: filteredRuns)
                HeartRateZonesCardView(runs: filteredRuns)
                PaceCardView(splits: filteredRuns.splits)
                RunningEfficiencyCardView(runs: filteredRuns)
                CadenceCardView(runs: filteredRuns)
            }
            .padding()
        }
        .scrollEdgeEffectHidden(true, for: .top)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("户外跑步")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsRunFilter = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.blue)
                }
                .accessibilityLabel("选择跑步数据")
            }
        }
        .fullScreenCover(isPresented: $showsRunFilter) {
            RunFilterView(runs: runs, includedRunIDs: $includedRunIDs)
        }
        .onChange(of: includedRunIDs) { _, selectedIDs in
            let allRunIDs = Set(runs.map(\.id))
            RunSelectionPreferences.saveExcludedRunIDs(allRunIDs.subtracting(selectedIDs))
        }
    }

    private var filteredRuns: [OutdoorRun] {
        runs.filter { includedRunIDs.contains($0.id) }
    }

}

private struct WeeklyRunSummaryView: View {
    let runs: [OutdoorRun]
    @State private var selectedWeekOffset: Int? = 0

    private var calendar: Calendar { .autoupdatingCurrent }

    private var weeklyInterval: DateInterval? {
        calendar.dateInterval(of: .weekOfYear, for: Date())
    }

    private var weeklyRuns: [OutdoorRun] {
        guard let interval = weeklyInterval else { return [] }
        return runs.filter {
            $0.startDate >= interval.start && $0.startDate < interval.end
        }
    }

    private func weekDates(offset: Int) -> [Date] {
        guard let start = weeklyInterval?.start else { return [] }
        guard let weekStart = calendar.date(byAdding: .weekOfYear, value: offset, to: start) else {
            return []
        }
        return (0..<7).compactMap {
            calendar.date(byAdding: .day, value: $0, to: weekStart)
        }
    }

    private var distanceKilometers: Double {
        weeklyRuns.reduce(0) { $0 + $1.distanceKm }
    }

    private var durationSeconds: TimeInterval {
        weeklyRuns.reduce(0) { $0 + $1.duration }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 28) {
                metric(
                    title: "本周跑量",
                    value: String(format: "%.1f", distanceKilometers),
                    unit: "公里",
                    accessibilityValue: String(format: "%.1f 公里", distanceKilometers)
                )

                metric(
                    title: "跑步时间",
                    value: durationValue,
                    unit: durationUnit,
                    accessibilityValue: durationAccessibilityValue
                )
            }

            weekCalendar
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var weekCalendar: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(-3...0, id: \.self) { offset in
                    weekRow(offset: offset)
                        .containerRelativeFrame(.horizontal)
                        .id(offset)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $selectedWeekOffset)
        .frame(height: 38)
        .padding(.top, 16)
        .accessibilityLabel("周日历")
    }

    private func weekRow(offset: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(weekDates(offset: offset), id: \.self) { date in
                let hasRun = runs.contains {
                    calendar.isDate($0.startDate, inSameDayAs: date)
                }

                VStack {
                    Text(date.formatted(.dateTime.day()))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(hasRun ? Color.white : Color.primary)
                        .frame(width: 38, height: 38)
                        .background(
                            hasRun ? Color.orange : Color(.systemGray5),
                            in: Circle()
                        )
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "\(date.formatted(.dateTime.month().day().weekday(.wide)))，\(hasRun ? "已跑步" : "未跑步")"
                )
            }
        }
    }

    private func metric(
        title: String,
        value: String,
        unit: String,
        accessibilityValue: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.title.bold())
                    .fontDesign(.rounded)
                    .monospacedDigit()
                    .foregroundStyle(.primary)

                Text(unit)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
    }

    private var durationValue: String {
        let totalMinutes = max(0, Int(durationSeconds / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return String(format: "%d:%02d", hours, minutes)
        }
        return "\(minutes)"
    }

    private var durationUnit: String {
        durationSeconds >= 3_600 ? "时:分" : "分钟"
    }

    private var durationAccessibilityValue: String {
        let totalMinutes = max(0, Int(durationSeconds / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours) 小时 \(minutes) 分钟"
        }
        return "\(minutes) 分钟"
    }
}

private struct RunFilterView: View {
    let runs: [OutdoorRun]
    @Binding var includedRunIDs: Set<UUID>
    @Environment(\.dismiss) private var dismiss
    @State private var exportURL: URL?

    var body: some View {
        NavigationStack {
            List {
                ForEach(runs.reversed()) { run in
                    Button {
                        toggle(run.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: includedRunIDs.contains(run.id)
                                ? "checkmark.circle.fill"
                                : "circle")
                                .font(.title3)
                                .foregroundStyle(includedRunIDs.contains(run.id)
                                    ? Color.blue
                                    : Color(.systemGray3))
                                .frame(width: 24)

                            Text(run.startDate.formatted(.dateTime.month(.abbreviated).day().year()))
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text(duration(run.duration))
                                .monospacedDigit()
                                .frame(maxWidth: .infinity, alignment: .center)

                            Text(distance(run.distanceKm))
                                .monospacedDigit()
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.insetGrouped)
            .scrollEdgeEffectHidden(true, for: .top)
            .navigationTitle("选择跑步数据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbarBackgroundVisibility(.hidden, for: .bottomBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        if allRunsSelected {
                            includedRunIDs.removeAll()
                        } else {
                            includedRunIDs = Set(runs.map(\.id))
                        }
                    } label: {
                        Label(
                            allRunsSelected ? "取消全选" : "全选",
                            systemImage: allRunsSelected ? "circle" : "checkmark.circle"
                        )
                    }
                    .tint(.blue)
                    .disabled(runs.isEmpty)

                    if let exportURL {
                        ShareLink(item: exportURL, subject: Text("户外跑步数据")) {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                        .tint(.blue)
                    } else {
                        Button {} label: {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                        .disabled(true)
                    }
                }
            }
        }
        .task(id: selectionToken) {
            if let exportURL {
                try? FileManager.default.removeItem(at: exportURL)
            }
            exportURL = nil
            let selectedRuns = runs.filter { includedRunIDs.contains($0.id) }
            guard !selectedRuns.isEmpty else { return }
            let task = Task.detached { () -> URL? in
                try? OutdoorRunCSVExporter.export(selectedRuns)
            }
            let url = await task.value
            guard !Task.isCancelled else {
                if let url { try? FileManager.default.removeItem(at: url) }
                return
            }
            exportURL = url
        }
    }

    private var allRunsSelected: Bool {
        !runs.isEmpty && includedRunIDs.count == runs.count
    }

    private var selectionToken: String {
        includedRunIDs.map(\.uuidString).sorted().joined(separator: ",")
    }

    private func toggle(_ id: UUID) {
        if includedRunIDs.contains(id) {
            includedRunIDs.remove(id)
        } else {
            includedRunIDs.insert(id)
        }
    }

    private func distance(_ kilometers: Double) -> String {
        String(format: "%.2fkm", kilometers)
    }

    private func duration(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval.rounded())
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d时%02d分%02d秒", hours, minutes, seconds)
        }
        return String(format: "%d分%02d秒", minutes, seconds)
    }
}

private enum OutdoorRunCSVExporter {
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
        let format = "%.\(places)f"
        return String(format: format, locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func optionalDecimal(_ value: Double?, places: Int) -> String {
        guard let value else { return "" }
        return decimal(value, places: places)
    }
}

private enum RunSelectionPreferences {
    private static let excludedRunIDsKey = "excludedOutdoorRunIDs"

    static func loadExcludedRunIDs() -> Set<UUID> {
        let values = UserDefaults.standard.stringArray(forKey: excludedRunIDsKey) ?? []
        return Set(values.compactMap(UUID.init(uuidString:)))
    }

    static func saveExcludedRunIDs(_ identifiers: Set<UUID>) {
        let values = identifiers.map(\.uuidString).sorted()
        UserDefaults.standard.set(values, forKey: excludedRunIDsKey)
    }
}

struct AnalyticsCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.bold())
            content
        }
        .padding(20)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
    }
}

struct MetricPair: View {
    let leftTitle: String
    let leftValue: String
    let rightTitle: String
    let rightValue: String

    var body: some View {
        HStack(alignment: .top) {
            metric(title: leftTitle, value: leftValue)
            Spacer()
            metric(title: rightTitle, value: rightValue)
                .multilineTextAlignment(.trailing)
        }
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: title == rightTitle ? .trailing : .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
        }
    }
}

enum MetricFormatter {
    static func pace(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "—" }
        let rounded = Int(seconds.rounded())
        return "\(rounded / 60):\(String(format: "%02d", rounded % 60)) /km"
    }

    static func cadence(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(Int(value.rounded())) spm"
    }

    static func date(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day())
    }

    static func dateRange(workoutIDs: [UUID], dates: [UUID: Date]) -> String {
        let values = workoutIDs.compactMap { dates[$0] }.sorted()
        guard let first = values.first, let last = values.last else { return "日期未知" }
        if Calendar.current.isDate(first, inSameDayAs: last) {
            return date(first)
        }
        return "\(date(first))–\(date(last))"
    }
}

struct ChartTooltip: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text(value)
                .font(.caption.monospacedDigit())
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        .allowsHitTesting(false)
    }
}
