import Charts
import SwiftUI

struct PaceCardView: View {
    let splits: [KilometerSplit]
    @State private var selectedBarIndex: Int?
    private let visibleCount = 10
    private let barSlot: CGFloat = 27
    private let healthOrange = Color(red: 1, green: 0.29, blue: 0)

    private var average: Double? {
        splits.isEmpty ? nil : splits.map(\.paceSecondsPerKm).reduce(0, +) / Double(splits.count)
    }

    private var fastest: Double? { splits.map(\.paceSecondsPerKm).min() }
    private var latest: Double? { splits.last?.paceSecondsPerKm }
    private var upperPaceMinutes: Double {
        max(1, ceil((splits.map(\.paceSecondsPerKm).max() ?? 60) / 60))
    }

    private var paceScaleLowerBound: Double {
        runEndMarkerMinutes * 1.5
    }

    private var runEndMarkerMinutes: Double {
        -max(0.25, upperPaceMinutes * 0.04)
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
                GeometryReader { geometry in
                    ZStack(alignment: .top) {
                        ScrollView(.horizontal) {
                            Chart {
                                ForEach(Array(splits.enumerated()), id: \.element.id) { index, split in
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
                            .chartXScale(domain: -0.5...(Double(max(visibleCount, splits.count)) - 0.5))
                            .chartYScale(domain: paceScaleLowerBound...upperPaceMinutes)
                            .chartXAxis(.hidden)
                            .chartYAxis(.hidden)
                            .chartXSelection(value: $selectedBarIndex)
                            .frame(width: max(geometry.size.width, CGFloat(splits.count) * barSlot), height: 190)
                        }
                        .defaultScrollAnchor(.trailing)
                        .scrollIndicators(.hidden)

                        if let selectedSplit {
                            ChartTooltip(
                                title: MetricFormatter.date(selectedSplit.startTime),
                                value: MetricFormatter.pace(selectedSplit.paceSecondsPerKm),
                                detail: "第 \(selectedSplit.kilometerIndex) 公里"
                            )
                        }
                    }
                }
                .frame(height: 190)

                Divider()
                paceSummary
            }
        }
    }

    private var paceSummary: some View {
        HStack(alignment: .top, spacing: 12) {
            paceMetric("平均配速", value: MetricFormatter.pace(average))
            Spacer(minLength: 0)
            paceMetric("最快配速", value: MetricFormatter.pace(fastest))
            Spacer(minLength: 0)
            paceMetric(
                "最近配速",
                value: MetricFormatter.pace(latest),
                alignment: .trailing
            )
        }
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
        splits.count < visibleCount ? visibleCount - splits.count + index : index
    }

    private var selectedSplit: KilometerSplit? {
        guard let selectedBarIndex else { return nil }
        let index = splits.count < visibleCount
            ? selectedBarIndex - (visibleCount - splits.count)
            : selectedBarIndex
        guard splits.indices.contains(index) else { return nil }
        return splits[index]
    }

    private func unavailable(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 140)
    }
}
