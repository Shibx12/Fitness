import Charts
import SwiftUI

struct HeartRateZonesCardView: View {
    let runs: [OutdoorRun]
    @State private var period: Period = .sevenDays
    @State private var selectedZone: Int?
    @State private var selectedHeartRateSeconds: Int?
    @State private var chartSelectionSeconds: Int?
    @State private var selectedWorkoutID: UUID?
    @State private var chartHeartRatePoints: [ZoneHeartRatePoint] = []

    private enum Period: Int, CaseIterable, Identifiable {
        case sevenDays = 7
        case thirtyDays = 30

        var id: Int { rawValue }
        var title: String { "\(rawValue)天" }
    }

    private struct ZoneSummary: Identifiable {
        let id: Int
        let name: String
        let color: Color
        let medianPercentage: Double
        let medianMinutes: Double
        let heartRateRange: String
    }

    fileprivate struct ZoneHeartRatePoint: Identifiable {
        let id: String
        let workoutID: UUID
        let workoutSeriesID: String
        let workoutDate: Date
        let elapsedSeconds: Int
        let heartRateBPM: Double
        let isHighlighted: Bool
        let highlightSeriesID: String?
    }

    private let zoneColors: [Color] = [
        Color(.systemGray), .blue, .green, .orange, .red
    ]

    var body: some View {
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

            if zoneSummaries.isEmpty || zoneSummaries.allSatisfy({ $0.medianPercentage == 0 }) {
                Text("此时间范围内没有 Apple 心率区间数据")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                GeometryReader { geometry in
                    let spacing: CGFloat = 3
                    let availableWidth = max(0, geometry.size.width - spacing * 4)
                    HStack(spacing: spacing) {
                        ForEach(zoneSummaries) { zone in
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(zone.color)
                                .frame(width: availableWidth * normalizedFraction(for: zone))
                                .opacity(selectedZone == nil || selectedZone == zone.id ? 1 : 0.42)
                                .contentShape(Rectangle())
                                .onTapGesture { select(zone.id) }
                                .accessibilityLabel("\(zone.name)，\(percentage(zone.medianPercentage))")
                        }
                    }
                }
                .frame(height: 20)

                HStack(alignment: .top, spacing: 4) {
                    ForEach(zoneSummaries) { zone in
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

                                Text(percentage(zone.medianPercentage))
                                    .font(.headline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .monospacedDigit()
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let selectedSummary {
                    VStack(spacing: 16) {
                        Text("\(selectedSummary.name) · 中位时长 \(minutes(selectedSummary.medianMinutes)) · \(selectedSummary.heartRateRange)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)

                        zoneTimeline(color: selectedSummary.color)
                    }
                    .clipped()
                    .transition(.opacity)
                }
            }
        }
    }

    private var periodRuns: [OutdoorRun] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let start = calendar.date(byAdding: .day, value: -(period.rawValue - 1), to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: today) else { return [] }
        return runs.filter { $0.startDate >= start && $0.startDate < end }
    }

    private var zoneSummaries: [ZoneSummary] {
        let runsWithZones = periodRuns.filter { !$0.heartRateZones.isEmpty }
        guard !runsWithZones.isEmpty else { return [] }

        return (0..<5).map { zone in
            let values = runsWithZones.compactMap { distribution(for: $0, zone: zone) }
            return ZoneSummary(
                id: zone,
                name: "Z\(zone + 1)",
                color: zoneColors[zone],
                medianPercentage: median(values.map(\.percentage)),
                medianMinutes: median(values.map(\.minutes)),
                heartRateRange: latestRangeLabel(zone: zone, in: runsWithZones)
            )
        }
    }

    private func distribution(
        for run: OutdoorRun,
        zone index: Int
    ) -> (percentage: Double, minutes: Double)? {
        let total = run.heartRateZones.reduce(0) { $0 + max(0, $1.duration) }
        guard total > 0 else { return nil }
        let duration = max(0, run.heartRateZones.first { $0.index == index }?.duration ?? 0)
        return (duration / total * 100, duration / 60)
    }

    private var selectedSummary: ZoneSummary? {
        guard let selectedZone else { return nil }
        return zoneSummaries.first { $0.id == selectedZone }
    }

    private func normalizedFraction(for zone: ZoneSummary) -> Double {
        let total = zoneSummaries.reduce(0) { $0 + $1.medianPercentage }
        guard total > 0 else { return 0 }
        return zone.medianPercentage / total
    }

    private func select(_ zone: Int) {
        let animation: Animation = selectedZone == zone
            ? .easeOut(duration: 0.16)
            : .snappy
        withAnimation(animation) {
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
            Text("此时间范围内没有可定位的心率时间序列")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80)
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
                            .foregroundStyle(showsAllWorkouts ? color.opacity(0.55) : color)
                            .lineStyle(StrokeStyle(
                                lineWidth: showsAllWorkouts ? 2 : 3,
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
                            withAnimation(.snappy) {
                                if isActive {
                                    selectedWorkoutID = nil
                                } else {
                                    selectedWorkoutID = run.id
                                    if let selectedZone {
                                        let defaultSeconds = rightmostHighlightedSecond(
                                            zone: selectedZone,
                                            workoutID: run.id
                                        )
                                        selectedHeartRateSeconds = defaultSeconds
                                        chartSelectionSeconds = defaultSeconds
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 9) {
                                Capsule()
                                    .fill(isActive ? color : Color(.systemGray4))
                                    .frame(width: 16, height: 4)

                                Text(runDate(run.startDate))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)

                                Spacer(minLength: 12)

                                if let point {
                                    Text("\(Int(point.heartRateBPM.rounded())) bpm")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                } else if selectedHeartRateSeconds != nil {
                                    Text("—")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
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
            let zone = run.heartRateZones.first { $0.index == selectedZone }
            let workoutSeriesID = run.id.uuidString
            var highlightSegment = 0
            var previousWasHighlighted = false

            for sample in displaySamples(for: run, zone: zone) {
                let highlighted = zone.map { contains(sample.averageBPM, in: $0) } ?? false
                if highlighted && !previousWasHighlighted {
                    highlightSegment += 1
                }
                let highlightSeriesID = highlighted
                    ? "\(run.id.uuidString)-zone-\(selectedZone)-\(highlightSegment)"
                    : nil

                result.append(ZoneHeartRatePoint(
                    id: "\(workoutSeriesID)-\(sample.elapsedSeconds)",
                    workoutID: run.id,
                    workoutSeriesID: workoutSeriesID,
                    workoutDate: run.startDate,
                    elapsedSeconds: sample.elapsedSeconds,
                    heartRateBPM: sample.averageBPM,
                    isHighlighted: highlighted,
                    highlightSeriesID: highlightSeriesID
                ))
                previousWasHighlighted = highlighted
            }
        }
        return result
    }

    private func displaySamples(
        for run: OutdoorRun,
        zone: WorkoutHeartRateZone?
    ) -> [MinuteHeartRate] {
        let samples = run.minuteHeartRateData.sorted { $0.elapsedSeconds < $1.elapsedSeconds }
        let maximumBasePoints = 96
        guard samples.count > maximumBasePoints else { return samples }

        let step = max(1, Int(ceil(Double(samples.count - 1) / Double(maximumBasePoints - 1))))
        var retainedIndices: Set<Int> = [0, samples.count - 1]

        for index in stride(from: 0, to: samples.count, by: step) {
            retainedIndices.insert(index)
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

        return retainedIndices.sorted().map { samples[$0] }
    }

    private var longestRunSeconds: Int {
        max(10, periodRuns.compactMap { $0.minuteHeartRateData.last?.elapsedSeconds }.max() ?? 10)
    }

    private var timelineRuns: [OutdoorRun] {
        periodRuns
            .filter { !$0.minuteHeartRateData.isEmpty }
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
                in: run.minuteHeartRateData,
                to: selectedHeartRateSeconds
            ) else { return nil }

            return ZoneHeartRatePoint(
                id: sample.id,
                workoutID: run.id,
                workoutSeriesID: run.id.uuidString,
                workoutDate: run.startDate,
                elapsedSeconds: sample.elapsedSeconds,
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
        return elapsedSeconds - preceding.elapsedSeconds
            <= following.elapsedSeconds - elapsedSeconds
            ? preceding
            : following
    }

    private func rightmostHighlightedSecond(zone index: Int, workoutID: UUID) -> Int? {
        guard let run = timelineRuns.first(where: { $0.id == workoutID }),
              let zone = run.heartRateZones.first(where: { $0.index == index }) else { return nil }

        return run.minuteHeartRateData
            .last(where: { contains($0.averageBPM, in: zone) })?
            .elapsedSeconds
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

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private func percentage(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    private func minutes(_ value: Double) -> String {
        String(format: "%.1f 分钟", value)
    }

    private func runDate(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().weekday(.abbreviated).hour().minute())
    }

    private func latestRangeLabel(zone index: Int, in runs: [OutdoorRun]) -> String {
        var latestValue: WorkoutHeartRateZone?
        for run in runs.sorted(by: { $0.startDate > $1.startDate }) {
            if let value = run.heartRateZones.first(where: { $0.index == index }) {
                latestValue = value
                break
            }
        }
        guard let value = latestValue else { return "Apple 区间" }

        switch (value.minimumBPM, value.maximumBPM) {
        case let (minimum?, maximum?):
            return "\(Int(minimum.rounded()))–\(Int(maximum.rounded())) bpm"
        case let (minimum?, nil):
            return "\(Int(minimum.rounded())) bpm 以上"
        case let (nil, maximum?):
            return "低于 \(Int(maximum.rounded())) bpm"
        case (nil, nil):
            return "Apple 区间"
        }
    }
}
