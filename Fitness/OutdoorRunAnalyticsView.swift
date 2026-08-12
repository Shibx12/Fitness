import SwiftUI

struct OutdoorRunAnalyticsView: View {
    let runs: [OutdoorRun]
    @State private var includedRunIDs: Set<UUID>
    @State private var showsRunFilter = false

    init(runs: [OutdoorRun]) {
        self.runs = runs
        let allRunIDs = Set(runs.map(\.id))
        _includedRunIDs = State(
            initialValue: RunSelectionPreferences.loadSelectedRunIDs(
                availableRunIDs: allRunIDs
            )
        )
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
        .onAppear {
            saveSelection()
        }
        .onChange(of: allRunIDs) { previousRunIDs, currentRunIDs in
            let newlyAvailableRunIDs = currentRunIDs.subtracting(previousRunIDs)
            let updatedSelection = includedRunIDs
                .intersection(currentRunIDs)
                .union(newlyAvailableRunIDs)
            includedRunIDs = updatedSelection
            RunSelectionPreferences.saveSelectedRunIDs(
                updatedSelection,
                availableRunIDs: currentRunIDs
            )
        }
        .onChange(of: includedRunIDs) { _, selectedIDs in
            RunSelectionPreferences.saveSelectedRunIDs(
                selectedIDs,
                availableRunIDs: allRunIDs
            )
        }
    }

    private var allRunIDs: Set<UUID> {
        Set(runs.map(\.id))
    }

    private func saveSelection(availableRunIDs: Set<UUID>? = nil) {
        RunSelectionPreferences.saveSelectedRunIDs(
            includedRunIDs,
            availableRunIDs: availableRunIDs ?? allRunIDs
        )
    }

    private var filteredRuns: [OutdoorRun] {
        runs.filter { includedRunIDs.contains($0.id) }
    }
}

private struct WeeklyRunSummaryView: View {
    let runs: [OutdoorRun]
    @State private var selectedWeekOffset: Int? = 0
    @State private var isWeekCalendarScrolling = false

    private var calendar: Calendar { .autoupdatingCurrent }

    private var currentWeekInterval: DateInterval? {
        calendar.dateInterval(of: .weekOfYear, for: Date())
    }

    private var weeklyRuns: [OutdoorRun] {
        guard let interval = weekInterval(offset: selectedWeekOffset ?? 0) else { return [] }
        return runs.filter {
            $0.startDate >= interval.start && $0.startDate < interval.end
        }
    }

    private func weekInterval(offset: Int) -> DateInterval? {
        guard let current = currentWeekInterval,
              let start = calendar.date(byAdding: .weekOfYear, value: offset, to: current.start),
              let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) else {
            return nil
        }
        return DateInterval(start: start, end: end)
    }

    private func weekDates(offset: Int) -> [Date] {
        guard let weekStart = weekInterval(offset: offset)?.start else { return [] }
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
                    title: weeklyDistanceTitle,
                    value: distanceKilometers.formatted(
                        .number.precision(.fractionLength(1)).locale(.autoupdatingCurrent)
                    ),
                    unit: L10n.string("公里"),
                    accessibilityValue: L10n.string(
                        "\(distanceKilometers, format: .number.precision(.fractionLength(1))) 公里"
                    )
                )

                metric(
                    title: L10n.string("跑步时间"),
                    value: durationValue,
                    unit: durationUnit,
                    accessibilityValue: durationAccessibilityValue
                )
            }
            .padding(.horizontal, 4)

            weekCalendar
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .scrollEdgeEffectHidden(true, for: [.leading, .trailing])
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $selectedWeekOffset)
        .onScrollPhaseChange { _, phase in
            isWeekCalendarScrolling = phase.isScrolling
        }
        .frame(height: 38)
        .mask {
            if isWeekCalendarScrolling {
                HStack(spacing: 0) {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black.opacity(0.25), location: 0.25),
                            .init(color: .black.opacity(0.72), location: 0.60),
                            .init(color: .black, location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 30)

                    Rectangle().fill(.black)

                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black.opacity(0.72), location: 0.40),
                            .init(color: .black.opacity(0.25), location: 0.75),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 30)
                }
            } else {
                Rectangle().fill(.black)
            }
        }
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
                    Text(date, format: .dateTime.day())
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
                    L10n.string(
                        "\(MetricFormatter.monthDayWeekday(date))，\(hasRun ? L10n.string("已跑步") : L10n.string("未跑步"))"
                    )
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
        durationSeconds >= 3_600 ? L10n.string("时:分") : L10n.string("分钟")
    }

    private var weeklyDistanceTitle: String {
        (selectedWeekOffset ?? 0) == 0 ? L10n.string("本周跑量") : L10n.string("周跑量")
    }

    private var durationAccessibilityValue: String {
        let totalMinutes = max(0, Int(durationSeconds / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return L10n.string("\(hours) 小时 \(minutes) 分钟")
        }
        return L10n.string("\(minutes) 分钟")
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

                            Text(MetricFormatter.date(run.startDate))
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
                            allRunsSelected ? L10n.string("取消全选") : L10n.string("全选"),
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
        "\(kilometers.formatted(.number.precision(.fractionLength(2)).locale(.autoupdatingCurrent))) km"
    }

    private func duration(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval.rounded())
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return L10n.string("\(hours)时\(minutes)分\(seconds)秒")
        }
        return L10n.string("\(minutes)分\(seconds)秒")
    }
}
