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
        let selectedRuns = filteredRuns
        ScrollView {
            LazyVStack(spacing: 16) {
                WeeklyRunSummaryView(runs: selectedRuns)
                HeartRateZonesCardView(runs: selectedRuns)
                LatestRunVitalsCardView(runs: selectedRuns)
                PaceCardView(splits: selectedRuns.splits)
                RunningEfficiencyCardView(runs: selectedRuns)
                CadenceCardView(runs: selectedRuns)
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
            RunSelectionPreferences.saveSelectedRunIDs(
                includedRunIDs,
                availableRunIDs: allRunIDs
            )
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

    private var filteredRuns: [OutdoorRun] {
        runs.filter { includedRunIDs.contains($0.id) }
    }
}

private struct WeeklyRunSummaryView: View {
    let runs: [OutdoorRun]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
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

    private var totalDistanceKilometers: Double {
        runs.reduce(0) { $0 + $1.distanceKm }
    }

    private var durationSeconds: TimeInterval {
        weeklyRuns.reduce(0) { $0 + $1.duration }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 14) {
                        weeklyMetrics
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 28) {
                            weeklyMetrics
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            weeklyMetrics
                        }
                    }
                }
            }
            .padding(.horizontal, 4)

            weekCalendar
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var weeklyMetrics: some View {
                metric(
                    title: L10n.string("全部跑量"),
                    value: totalDistanceKilometers.formatted(
                        .number.precision(.fractionLength(1)).locale(.autoupdatingCurrent)
                    ),
                    unit: L10n.string("公里"),
                    accessibilityValue: L10n.string(
                        "\(totalDistanceKilometers, format: .number.precision(.fractionLength(1))) 公里"
                    )
                )

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
                    Text(verbatim: String(calendar.component(.day, from: date)))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(hasRun ? Color.black : Color.primary)
                        .frame(width: 38, height: 38)
                        .background(
                            hasRun ? Color.orange : Color(.systemGray5),
                            in: Circle()
                        )
                        .overlay {
                            if hasRun, differentiateWithoutColor {
                                Circle()
                                    .strokeBorder(Color.primary, lineWidth: 2)
                            }
                        }
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var store: HealthDataStore
    @State private var exportArtifact: ExportArtifact?
    @State private var exportedFileURL: URL?
    @State private var exportTask: Task<Void, Never>?
    @State private var isExporting = false
    @State private var exportErrorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(runs.reversed()) { run in
                    Button {
                        toggle(run.id)
                    } label: {
                        Group {
                            if dynamicTypeSize.isAccessibilitySize {
                                runSelectionRow(run, vertical: true)
                            } else {
                                ViewThatFits(in: .horizontal) {
                                    runSelectionRow(run, vertical: false)
                                    runSelectionRow(run, vertical: true)
                                }
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(runAccessibilityLabel(run))
                        .accessibilityValue(
                            includedRunIDs.contains(run.id) ? "已选择" : "未选择"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.insetGrouped)
            .refreshable {
                await store.refresh()
            }
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

                    Button(action: exportSelectedRuns) {
                        if isExporting {
                            ProgressView()
                                .accessibilityLabel("正在导出跑步数据")
                        } else {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                    }
                    .tint(.blue)
                    .disabled(isExporting || includedRunIDs.isEmpty)
                }
            }
        }
        .sheet(item: $exportArtifact, onDismiss: removeExportFile) { artifact in
            ActivityView(activityItems: [artifact.url])
                .ignoresSafeArea()
        }
        .alert("无法导出跑步数据", isPresented: Binding(
            get: { exportErrorMessage != nil },
            set: { if !$0 { exportErrorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(exportErrorMessage ?? "")
        }
        .onDisappear {
            exportTask?.cancel()
            removeExportFile()
        }
    }

    @ViewBuilder
    private func runSelectionRow(_ run: OutdoorRun, vertical: Bool) -> some View {
        let selection = Image(systemName: includedRunIDs.contains(run.id)
            ? "checkmark.circle.fill"
            : "circle")
            .font(.title3)
            .foregroundStyle(includedRunIDs.contains(run.id)
                ? Color.blue
                : Color(.systemGray3))
            .frame(width: 24)

        if vertical {
            HStack(alignment: .top, spacing: 10) {
                selection
                VStack(alignment: .leading, spacing: 4) {
                    Text(MetricFormatter.date(run.startDate))
                    Text("\(duration(run.duration)) · \(distance(run.distanceKm))")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.subheadline)
            .foregroundStyle(.primary)
        } else {
            HStack(spacing: 10) {
                selection
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
        }
    }

    private func runAccessibilityLabel(_ run: OutdoorRun) -> String {
        "\(MetricFormatter.date(run.startDate))，\(duration(run.duration))，\(distance(run.distanceKm))"
    }

    private var allRunsSelected: Bool {
        !runs.isEmpty && includedRunIDs.count == runs.count
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

    private func exportSelectedRuns() {
        let selectedRuns = runs.filter { includedRunIDs.contains($0.id) }
        guard !selectedRuns.isEmpty else { return }
        exportTask?.cancel()
        removeExportFile()
        isExporting = true

        exportTask = Task {
            do {
                let healthData = try await store.exportData(
                    for: Set(selectedRuns.map(\.id))
                )
                try Task.checkCancellation()
                let url = try await withThrowingTaskGroup(of: URL.self) { group in
                    group.addTask(priority: .userInitiated) {
                        try OutdoorRunCSVExporter.export(
                            selectedRuns,
                            healthData: healthData
                        )
                    }
                    guard let url = try await group.next() else {
                        throw CancellationError()
                    }
                    return url
                }
                exportedFileURL = url
                try Task.checkCancellation()
                exportArtifact = ExportArtifact(url: url)
            } catch is CancellationError {
                removeExportFile()
            } catch {
                removeExportFile()
                exportErrorMessage = L10n.string("请稍后重试。")
            }
            isExporting = false
        }
    }

    private func removeExportFile() {
        if let exportedFileURL {
            try? FileManager.default.removeItem(at: exportedFileURL)
        }
        exportedFileURL = nil
        exportArtifact = nil
    }
}
