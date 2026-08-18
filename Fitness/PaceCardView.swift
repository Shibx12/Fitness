import Charts
import SwiftUI

struct PaceCardView: View {
    let splits: [KilometerSplit]
    @State private var selectedBarIndex: Int?
    @State private var scrollPosition: Int
    private static let visibleCount = 10
    private let healthOrange = Color(red: 1, green: 0.29, blue: 0)

    init(splits: [KilometerSplit]) {
        self.splits = splits
        let initialPosition = splits.count < Self.visibleCount
            ? Self.visibleCount - 1
            : max(0, splits.count - 1)
        _scrollPosition = State(initialValue: initialPosition)
    }

    private var average: Double? {
        splits.isEmpty ? nil : splits.map(\.paceSecondsPerKm).reduce(0, +) / Double(splits.count)
    }

    private var fastest: Double? { splits.map(\.paceSecondsPerKm).min() }
    private var latest: Double? {
        let workouts = Dictionary(grouping: splits, by: \.workoutID).values.compactMap {
            workoutSplits -> (date: Date, splits: [KilometerSplit])? in
            guard let date = workoutSplits.map(\.startTime).min() else { return nil }
            return (date, workoutSplits)
        }
        guard let latestSplits = workouts.max(by: { $0.date < $1.date })?.splits else {
            return nil
        }
        return latestSplits.map(\.paceSecondsPerKm).reduce(0, +) / Double(latestSplits.count)
    }
    private var upperPaceMinutes: Double {
        max(1, ceil((splits.map(\.paceSecondsPerKm).max() ?? 60) / 60))
    }

    private var paceScaleLowerBound: Double {
        runEndMarkerMinutes * 1.35
    }

    private var runEndMarkerMinutes: Double {
        -max(0.3, upperPaceMinutes * 0.048)
    }

    private var lastSplitIDs: Set<String> {
        let grouped = Dictionary(grouping: splits, by: \.workoutID)
        return Set(grouped.values.compactMap { workoutSplits in
            workoutSplits.max { $0.kilometerIndex < $1.kilometerIndex }?.id
        })
    }

    var body: some View {
        AnalyticsCard(title: "配速") {
            if splits.isEmpty {
                unavailable("没有完整的 1 公里分段")
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(spacing: 6) {
                        Chart {
                            ForEach(visibleSplits, id: \.element.id) { index, split in
                                BarMark(
                                    x: .value("分段", displayIndex(index)),
                                    y: .value("配速（分钟）", split.paceSecondsPerKm / 60),
                                    width: .fixed(13)
                                )
                                .foregroundStyle(healthOrange)
                                .cornerRadius(5)

                                if lastSplitIDs.contains(split.id) {
                                    PointMark(
                                        x: .value("分段", displayIndex(index)),
                                        y: .value("跑步结束", runEndMarkerMinutes)
                                    )
                                    .foregroundStyle(healthOrange)
                                    .symbolSize(18)
                                    .accessibilityLabel("本次跑步的最后一公里")
                                }
                            }
                            if let average {
                                RuleMark(y: .value("平均配速", average / 60))
                                    .foregroundStyle(healthOrange)
                                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            }
                        }
                        .chartXScale(domain: -0.5...(Double(max(Self.visibleCount, splits.count)) - 0.5))
                        .chartYScale(domain: paceScaleLowerBound...upperPaceMinutes)
                        .chartXAxis(.hidden)
                        .chartYAxis(.hidden)
                        .chartScrollableAxes(.horizontal)
                        .chartXVisibleDomain(length: Self.visibleCount)
                        .chartScrollPosition(x: $scrollPosition)
                        .chartXSelection(value: $selectedBarIndex)
                        .frame(height: 190)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("配速图表")
                        .accessibilityValue("共 \(splits.count) 个一公里分段")

                        Divider()
                    }

                    paceSummary
                }
            }
        }
    }

    private var paceSummary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                paceMetric(L10n.string("平均配速"), value: MetricFormatter.pace(average))
                Spacer(minLength: 0)
                paceMetric(L10n.string("最快配速"), value: MetricFormatter.pace(fastest))
                Spacer(minLength: 0)
                paceMetric(
                    selectedPaceTitle,
                    value: MetricFormatter.pace(selectedSplit?.paceSecondsPerKm ?? latest),
                    alignment: .trailing
                )
            }
            VStack(alignment: .leading, spacing: 10) {
                paceMetric(L10n.string("平均配速"), value: MetricFormatter.pace(average))
                paceMetric(L10n.string("最快配速"), value: MetricFormatter.pace(fastest))
                paceMetric(
                    selectedPaceTitle,
                    value: MetricFormatter.pace(selectedSplit?.paceSecondsPerKm ?? latest)
                )
            }
        }
    }

    private var selectedPaceTitle: String {
        guard let selectedSplit else { return L10n.string("最近配速") }
        return L10n.string("\(MetricFormatter.monthDay(selectedSplit.startTime))配速")
    }

    private func paceMetric(
        _ title: String,
        value: String,
        alignment: HorizontalAlignment = .leading
    ) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private func displayIndex(_ index: Int) -> Int {
        splits.count < Self.visibleCount ? Self.visibleCount - splits.count + index : index
    }

    private var selectedSplit: KilometerSplit? {
        guard let selectedBarIndex else { return nil }
        let index = splits.count < Self.visibleCount
            ? selectedBarIndex - (Self.visibleCount - splits.count)
            : selectedBarIndex
        guard splits.indices.contains(index) else { return nil }
        return splits[index]
    }

    private var visibleSplits: [(offset: Int, element: KilometerSplit)] {
        guard splits.count > Self.visibleCount else { return Array(splits.enumerated()) }
        let range = ChartWindow.range(
            itemCount: splits.count,
            visibleCount: Self.visibleCount,
            scrollPosition: scrollPosition,
            padding: 6
        )
        return splits[range].enumerated().map {
            (offset: range.lowerBound + $0.offset, element: $0.element)
        }
    }

    private func unavailable(_ text: LocalizedStringResource) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 140)
    }
}
