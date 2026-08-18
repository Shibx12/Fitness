import Charts
import SwiftUI

struct HeartRateZonesCardView: View {
    let runs: [OutdoorRun]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var period: Period = .sevenDays
    @State private var selectedZone: Int?
    @State private var selectedHeartRateSeconds: Int?
    @State private var chartSelectionSeconds: Int?
    @State private var selectedWorkoutID: UUID?
    @State private var chartHeartRatePoints: [ZoneHeartRatePoint] = []

    private enum Period: CaseIterable, Identifiable {
        case sevenDays
        case thirtyDays
        case all

        var id: Self { self }

        var title: LocalizedStringResource {
            switch self {
            case .sevenDays: "7天"
            case .thirtyDays: "30天"
            case .all: "全部"
            }
        }

        var dayCount: Int? {
            switch self {
            case .sevenDays: 7
            case .thirtyDays: 30
            case .all: nil
            }
        }
    }

    private struct ZoneSummary: Identifiable {
        let id: Int
        let name: String
        let color: Color
        let percentage: Double
        let totalMinutes: Double
        let heartRateRange: String
    }

    fileprivate struct ZoneHeartRatePoint: Identifiable {
        let id: String
        let workoutID: UUID
        let workoutSeriesID: String
        let elapsedSeconds: Int
        let workoutElapsedSeconds: Int
        let heartRateBPM: Double
        let isHighlighted: Bool
        let highlightSeriesID: String?
    }

    private struct DisplayHeartRateSample {
        let sample: MinuteHeartRate
        let lineSegment: Int
    }

    private let zoneColors: [Color] = [
        Color(.systemGray), .blue, .green, .orange, .red,
        .purple, .indigo, .cyan, .pink
    ]

    var body: some View {
        let analysis = periodAnalysis
        let summaries = makeZoneSummaries(from: analysis)
        AnalyticsCard(title: "心率区间") {
            Picker("时间范围", selection: $period) {
                ForEach(Period.allCases) { period in
                    Text(period.title).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: period) { _, _ in
                selectedZone = nil
                selectedHeartRateSeconds = nil
                chartSelectionSeconds = nil
                selectedWorkoutID = nil
                chartHeartRatePoints = []
            }
            .onChange(of: runIDs) { _, _ in
                selectedZone = nil
                selectedHeartRateSeconds = nil
                chartSelectionSeconds = nil
                selectedWorkoutID = nil
                chartHeartRatePoints = []
            }

            if summaries.isEmpty {
                Text("此跑步没有可用的 Apple Watch 心率区间数据")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                GeometryReader { geometry in
                    let spacing: CGFloat = 3
                    let availableWidth = max(
                        0,
                        geometry.size.width - spacing * CGFloat(max(0, summaries.count - 1))
                    )
                    HStack(spacing: spacing) {
                        ForEach(summaries) { zone in
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(zone.color)
                                .frame(width: availableWidth * normalizedFraction(for: zone, in: summaries))
                                .opacity(selectedZone == nil || selectedZone == zone.id ? 1 : 0.42)
                                .contentShape(Rectangle())
                                .onTapGesture { select(zone.id) }
                                .accessibilityLabel("\(zone.name)，\(percentage(zone.percentage))")
                        }
                    }
                }
                .frame(height: 20)
                .accessibilityHidden(true)

                zoneButtons(summaries)

                if let selectedSummary = summaries.first(where: { $0.id == selectedZone }) {
                    VStack(spacing: 16) {
                        Text("\(selectedSummary.name) · 累计 \(minutes(selectedSummary.totalMinutes)) · \(selectedSummary.heartRateRange)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)

                        zoneTimeline(color: selectedSummary.color)
                    }
                    .clipped()
                    .transition(reduceMotion ? .identity : .opacity)
                }

                if analysis.hasConfigurationVariation {
                    Text("所选跑步的 Apple Watch 区间边界或配置存在变化")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if analysis.workoutCountWithoutZones > 0 {
                    Text("\(analysis.workoutCountWithoutZones) 次跑步没有可用的 Apple Watch 心率区间数据")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private func zoneButtons(_ summaries: [ZoneSummary]) -> some View {
        if summaries.count <= 5 {
            HStack(alignment: .top, spacing: 4) {
                ForEach(summaries) { zone in
                    zoneButton(zone, fillsAvailableWidth: true)
                }
            }
        } else {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 4) {
                    ForEach(summaries) { zone in
                        zoneButton(zone, fillsAvailableWidth: false)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func zoneButton(
        _ zone: ZoneSummary,
        fillsAvailableWidth: Bool
    ) -> some View {
        Button { select(zone.id) } label: {
            VStack(spacing: 5) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(zone.color)
                        .frame(width: 7, height: 7)
                    Text(zone.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Text(percentage(zone.percentage))
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            }
            .frame(
                minWidth: fillsAvailableWidth ? nil : 52,
                maxWidth: fillsAvailableWidth ? .infinity : nil,
                minHeight: 44
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(zone.name)，\(percentage(zone.percentage))，\(zone.heartRateRange)")
        .accessibilityAddTraits(selectedZone == zone.id ? .isSelected : [])
    }

    private var periodRuns: [OutdoorRun] {
        guard let dayCount = period.dayCount else { return runs }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let start = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: today) else { return [] }
        return runs.filter { $0.startDate >= start && $0.startDate < end }
    }

    private func makeZoneSummaries(from analysis: HeartRateZoneAnalysis) -> [ZoneSummary] {
        analysis.summaries.map { summary in
            return ZoneSummary(
                id: summary.number,
                name: "Z\(summary.number)",
                color: zoneColor(number: summary.number),
                percentage: summary.percentage,
                totalMinutes: summary.duration / 60,
                heartRateRange: rangeLabel(summary.boundaries)
            )
        }
    }

    private var periodAnalysis: HeartRateZoneAnalysis {
        HeartRateZoneAnalysis.make(for: periodRuns)
    }

    private func normalizedFraction(
        for zone: ZoneSummary,
        in summaries: [ZoneSummary]
    ) -> Double {
        let total = summaries.reduce(0) { $0 + $1.percentage }
        guard total > 0 else { return 0 }
        return zone.percentage / total
    }

    private func select(_ zone: Int) {
        let animation: Animation = selectedZone == zone
            ? .easeOut(duration: 0.16)
            : .snappy
        withAnimation(reduceMotion ? nil : animation) {
            if selectedZone == zone {
                selectedZone = nil
                selectedHeartRateSeconds = nil
                chartSelectionSeconds = nil
                selectedWorkoutID = nil
            } else {
                let preparedPoints = makeChartHeartRatePoints(zone: zone)
                selectedZone = zone
                selectedWorkoutID = nil
                chartHeartRatePoints = preparedPoints
                selectedHeartRateSeconds = nil
                chartSelectionSeconds = nil
            }
        }
    }

    @ViewBuilder
    private func zoneTimeline(color: Color) -> some View {
        if chartHeartRatePoints.isEmpty {
            VStack(spacing: 12) {
                Text("此时间范围内没有可定位的心率时间序列")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 52)
                zoneRunSelectionPanel(color: color, selectedPoints: [:])
            }
        } else {
            let selectedPoints = Dictionary(
                uniqueKeysWithValues: selectedHeartRatePoints.map { ($0.workoutID, $0) }
            )
            let activePoint = activeWorkoutID.flatMap { selectedPoints[$0] }

            VStack(spacing: 12) {
                Chart {
                    ForEach(chartHeartRatePoints) { point in
                        let isActiveWorkout = point.workoutID == activeWorkoutID
                        let showsAllWorkouts = activeWorkoutID == nil

                        LineMark(
                            x: .value("运动时间", point.elapsedSeconds),
                            y: .value("心率", point.heartRateBPM),
                            series: .value("跑步", point.workoutSeriesID)
                        )
                        .foregroundStyle(
                            showsAllWorkouts
                                ? Color.primary.opacity(0.30)
                                : isActiveWorkout
                                ? Color.primary.opacity(0.52)
                                : Color(.systemGray4).opacity(0.58)
                        )
                        .lineStyle(StrokeStyle(
                            lineWidth: showsAllWorkouts ? 1.5 : (isActiveWorkout ? 2.2 : 1.2),
                            lineCap: .round,
                            lineJoin: .round
                        ))

                        if point.isHighlighted,
                           (showsAllWorkouts || isActiveWorkout),
                           let highlightSeriesID = point.highlightSeriesID {
                            LineMark(
                                x: .value("运动时间", point.elapsedSeconds),
                                y: .value("区间心率", point.heartRateBPM),
                                series: .value("区间片段", highlightSeriesID)
                            )
                            .foregroundStyle(color)
                            .lineStyle(StrokeStyle(
                                lineWidth: showsAllWorkouts ? 2.2 : 3,
                                lineCap: .round,
                                lineJoin: .round
                            ))
                        }
                    }

                    if let selectedHeartRateSeconds {
                        RuleMark(x: .value("当前运动时间", selectedHeartRateSeconds))
                            .foregroundStyle(color)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    }

                    if let activePoint {
                        PointMark(
                            x: .value("当前运动时间", selectedHeartRateSeconds ?? activePoint.elapsedSeconds),
                            y: .value("当前心率", activePoint.heartRateBPM)
                        )
                        .foregroundStyle(color)
                        .symbolSize(42)
                    }
                }
                .chartXScale(domain: 0...longestRunSeconds)
                .chartYScale(domain: heartRateDomain)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartXSelection(value: $chartSelectionSeconds)
                .onChange(of: chartSelectionSeconds) { _, seconds in
                    guard let seconds else { return }
                    selectedHeartRateSeconds = seconds
                    if selectedWorkoutID == nil {
                        selectedWorkoutID = timelineRuns.first?.id
                    }
                }
                .frame(height: 150)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("心率时间线")
                .accessibilityValue("共 \(timelineRuns.count) 次跑步")
                .transaction { transaction in
                    transaction.animation = nil
                }

                zoneRunSelectionPanel(color: color, selectedPoints: selectedPoints)
            }
        }
    }

    @ViewBuilder
    private func zoneRunSelectionPanel(
        color: Color,
        selectedPoints: [UUID: ZoneHeartRatePoint]
    ) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(timelineRuns) { run in
                        let isActive = run.id == activeWorkoutID
                        let point = selectedPoints[run.id]

                        Button {
                            withAnimation(reduceMotion ? nil : .snappy) {
                                if isActive {
                                    selectedWorkoutID = nil
                                } else {
                                    selectedWorkoutID = run.id
                                    let defaultSeconds = lastHeartRateSecond(workoutID: run.id)
                                    selectedHeartRateSeconds = defaultSeconds
                                    chartSelectionSeconds = defaultSeconds
                                }
                            }
                        } label: {
                            HStack(alignment: .top, spacing: 9) {
                                Capsule()
                                    .fill(isActive ? color : Color(.systemGray4))
                                    .frame(width: 16, height: 4)
                                    .padding(.top, 7)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(runDate(run.startDate))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)

                                    zoneDetailLine(for: run, point: point)
                                        .font(.caption2)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                        .monospacedDigit()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if run.id != timelineRuns.last?.id {
                            Divider()
                                .padding(.leading, 39)
                        }
                    }
                }
            }
            .frame(maxHeight: timelineRuns.count > 4 ? 158 : nil)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("各次跑步心率")
    }

    private func makeChartHeartRatePoints(zone selectedZone: Int) -> [ZoneHeartRatePoint] {
        var result: [ZoneHeartRatePoint] = []

        for run in periodRuns.sorted(by: { $0.startDate < $1.startDate }) {
            let zone = run.heartRateZoneConfiguration?.zones.first {
                $0.number == selectedZone
            }
            var highlightSegment = 0
            var previousWasHighlighted = false
            var previousLineSegment: Int?

            for displaySample in displaySamples(for: run, zone: zone) {
                let sample = displaySample.sample
                if previousLineSegment != displaySample.lineSegment {
                    previousWasHighlighted = false
                }
                let highlighted = zone.map { contains(sample.averageBPM, in: $0) } ?? false
                if highlighted && !previousWasHighlighted {
                    highlightSegment += 1
                }
                let highlightSeriesID = highlighted
                    ? "\(run.id.uuidString)-zone-\(selectedZone)-\(highlightSegment)"
                    : nil

                result.append(ZoneHeartRatePoint(
                    id: "\(run.id.uuidString)-\(sample.elapsedSeconds)",
                    workoutID: run.id,
                    workoutSeriesID: "\(run.id.uuidString)-segment-\(displaySample.lineSegment)",
                    elapsedSeconds: sample.elapsedSeconds,
                    workoutElapsedSeconds: sample.elapsedSeconds,
                    heartRateBPM: sample.averageBPM,
                    isHighlighted: highlighted,
                    highlightSeriesID: highlightSeriesID
                ))
                previousWasHighlighted = highlighted
                previousLineSegment = displaySample.lineSegment
            }
        }
        return result
    }

    private func displaySamples(
        for run: OutdoorRun,
        zone: WorkoutHeartRateZone?
    ) -> [DisplayHeartRateSample] {
        let samples = run.minuteHeartRateData.sorted { $0.elapsedSeconds < $1.elapsedSeconds }
        let lineSegments = HeartRateTimeline.segmentIndices(
            for: samples.map(\.elapsedSeconds)
        )
        let indexedSamples = samples.indices.map {
            DisplayHeartRateSample(sample: samples[$0], lineSegment: lineSegments[$0])
        }
        let maximumBasePoints = max(
            12,
            min(96, 1_500 / max(1, periodRuns.count))
        )
        guard samples.count > maximumBasePoints else { return indexedSamples }

        let step = max(1, Int(ceil(Double(samples.count - 1) / Double(maximumBasePoints - 1))))
        var retainedIndices: Set<Int> = [0, samples.count - 1]

        for index in stride(from: 0, to: samples.count, by: step) {
            retainedIndices.insert(index)
        }

        for chunkStart in stride(from: 0, to: samples.count, by: step) {
            let chunkEnd = min(samples.count, chunkStart + step)
            let chunk = samples[chunkStart..<chunkEnd]
            if let minimum = chunk.indices.min(by: {
                samples[$0].averageBPM < samples[$1].averageBPM
            }) {
                retainedIndices.insert(minimum)
            }
            if let maximum = chunk.indices.max(by: {
                samples[$0].averageBPM < samples[$1].averageBPM
            }) {
                retainedIndices.insert(maximum)
            }
        }

        if let zone {
            var wasHighlighted = contains(samples[0].averageBPM, in: zone)
            for index in 1..<samples.count {
                let isHighlighted = contains(samples[index].averageBPM, in: zone)
                if isHighlighted != wasHighlighted {
                    retainedIndices.insert(index - 1)
                    retainedIndices.insert(index)
                }
                wasHighlighted = isHighlighted
            }
        }

        return retainedIndices.sorted().map { indexedSamples[$0] }
    }

    private var longestRunSeconds: Int {
        max(10, periodRuns.compactMap {
            $0.minuteHeartRateData.max(by: { $0.elapsedSeconds < $1.elapsedSeconds })?.elapsedSeconds
        }.max() ?? 10)
    }

    private var timelineRuns: [OutdoorRun] {
        periodRuns
            .sorted { $0.startDate > $1.startDate }
    }

    private var runIDs: [UUID] {
        runs.map(\.id)
    }

    private var activeWorkoutID: UUID? {
        selectedWorkoutID
    }

    private var selectedHeartRatePoints: [ZoneHeartRatePoint] {
        guard let selectedHeartRateSeconds else { return [] }
        return timelineRuns.compactMap { run in
            guard let sample = closestHeartRateSample(
                in: run.minuteHeartRateData.sorted { $0.elapsedSeconds < $1.elapsedSeconds },
                to: selectedHeartRateSeconds
            ) else { return nil }

            return ZoneHeartRatePoint(
                id: sample.id,
                workoutID: run.id,
                workoutSeriesID: run.id.uuidString,
                elapsedSeconds: sample.elapsedSeconds,
                workoutElapsedSeconds: sample.elapsedSeconds,
                heartRateBPM: sample.averageBPM,
                isHighlighted: false,
                highlightSeriesID: nil
            )
        }
    }

    private func closestHeartRateSample(
        in samples: [MinuteHeartRate],
        to elapsedSeconds: Int
    ) -> MinuteHeartRate? {
        guard let first = samples.first,
              let last = samples.last,
              elapsedSeconds >= first.elapsedSeconds,
              elapsedSeconds <= last.elapsedSeconds else { return nil }

        var lower = 0
        var upper = samples.count - 1
        while lower < upper {
            let middle = (lower + upper) / 2
            if samples[middle].elapsedSeconds < elapsedSeconds {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        let following = samples[lower]
        guard lower > 0 else { return following }
        let preceding = samples[lower - 1]
        let closest = elapsedSeconds - preceding.elapsedSeconds
            <= following.elapsedSeconds - elapsedSeconds
            ? preceding
            : following
        return abs(closest.elapsedSeconds - elapsedSeconds) <= 15 ? closest : nil
    }

    private func lastHeartRateSecond(workoutID: UUID) -> Int? {
        timelineRuns.first(where: { $0.id == workoutID })?
            .minuteHeartRateData
            .map(\.elapsedSeconds)
            .max()
    }

    private var heartRateAxisValues: [Double] {
        let values = chartHeartRatePoints.map(\.heartRateBPM)
        guard let minimum = values.min(), let maximum = values.max() else { return [] }
        return minimum == maximum ? [minimum] : [minimum, maximum]
    }

    private var heartRateDomain: ClosedRange<Double> {
        guard let minimum = heartRateAxisValues.first,
              let maximum = heartRateAxisValues.last else { return 0...1 }
        if minimum == maximum { return (minimum - 1)...(maximum + 1) }
        return minimum...maximum
    }

    private func contains(_ heartRate: Double, in zone: WorkoutHeartRateZone) -> Bool {
        let aboveMinimum = zone.minimumBPM.map { heartRate >= $0 } ?? true
        let belowMaximum = zone.maximumBPM.map { heartRate < $0 } ?? true
        return aboveMinimum && belowMaximum
    }

    private func percentage(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    private func minutes(_ value: Double) -> String {
        L10n.string("\(value, format: .number.precision(.fractionLength(1))) 分钟")
    }

    private func elapsedTime(_ seconds: Int) -> String {
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    private func runDate(_ date: Date) -> String {
        MetricFormatter.monthDayWeekdayTime(date)
            .replacingOccurrences(
                of: #"(?<=\d)日"#,
                with: "",
                options: .regularExpression
            )
    }

    private func zoneColor(number: Int) -> Color {
        guard zoneColors.indices.contains(number - 1) else { return Color(.systemGray) }
        return zoneColors[number - 1]
    }

    private func zoneConfigurationSummary(
        for run: OutdoorRun,
        point: ZoneHeartRatePoint?
    ) -> String {
        guard let configuration = run.heartRateZoneConfiguration else {
            return L10n.string("此跑步没有可用的 Apple Watch 心率区间数据")
        }
        let displayedZone = point.flatMap { point in
            configuration.zones.first {
                contains(point.heartRateBPM, in: $0)
            }?.number
        } ?? selectedZone
        guard let displayedZone,
              let zone = configuration.zones.first(where: { $0.number == displayedZone }) else {
            return L10n.string("此跑步没有可用的 Apple Watch 心率区间数据")
        }
        let percentage = configuration.totalDuration > 0
            ? zone.duration / configuration.totalDuration * 100
            : 0
        return "Z\(zone.number) · \(rangeLabel(minimum: zone.minimumBPM, maximum: zone.maximumBPM)) · \(minutes(zone.duration / 60)) · \(self.percentage(percentage))"
    }

    @ViewBuilder
    private func zoneDetailLine(
        for run: OutdoorRun,
        point: ZoneHeartRatePoint?
    ) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: zoneConfigurationSummary(for: run, point: point))
            if let point {
                Spacer(minLength: 8)
                Text(verbatim: elapsedTime(point.workoutElapsedSeconds))
                Text(verbatim: "\(Int(point.heartRateBPM.rounded())) bpm")
            } else if selectedHeartRateSeconds != nil {
                Spacer(minLength: 8)
                Text(verbatim: "—")
            }
        }
        .foregroundStyle(.tertiary)
    }

    private func rangeLabel(_ boundaries: HeartRateZoneAnalysis.Summary.Boundaries) -> String {
        switch boundaries {
        case let .uniform(minimumBPM, maximumBPM):
            return rangeLabel(minimum: minimumBPM, maximum: maximumBPM)
        case .varied:
            return L10n.string("区间边界因跑步而异")
        }
    }

    private func rangeLabel(minimum: Double?, maximum: Double?) -> String {
        switch (minimum, maximum) {
        case let (minimum?, maximum?):
            return "\(Int(minimum.rounded()))–\(Int(maximum.rounded())) bpm"
        case let (minimum?, nil):
            return L10n.string("\(Int(minimum.rounded())) bpm 以上")
        case let (nil, maximum?):
            return L10n.string("低于 \(Int(maximum.rounded())) bpm")
        case (nil, nil):
            return L10n.string("Apple 区间")
        }
    }
}
