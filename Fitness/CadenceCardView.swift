import Charts
import SwiftUI

struct CadenceCardView: View {
    let runs: [OutdoorRun]
    @State private var selectedChartIndex: Int?
    private let visibleCount = 20
    private let barSlot: CGFloat = 14
    private let healthOrange = Color(red: 1, green: 0.29, blue: 0)

    private struct CadenceBucket: Identifiable {
        let id: String
        let index: Int
        let workoutDate: Date
        let elapsedMinute: Int
        let cadence: Double?
    }

    private var buckets: [CadenceBucket] {
        var result: [CadenceBucket] = []

        for run in runs.sorted(by: { $0.startDate < $1.startDate }) {
            let cadenceByMinute = Dictionary(
                uniqueKeysWithValues: run.minuteCadenceData.map { ($0.elapsedMinute, $0.stepsPerMinute) }
            )
            let wallClockMinutes = max(0, Int(run.endDate.timeIntervalSince(run.startDate) / 60))
            let finalMinute = max(wallClockMinutes, cadenceByMinute.keys.max() ?? 0)
            guard finalMinute > 0 else { continue }

            for minute in 1...finalMinute {
                result.append(CadenceBucket(
                    id: "\(run.id.uuidString)-\(minute)",
                    index: result.count,
                    workoutDate: run.startDate,
                    elapsedMinute: minute,
                    cadence: cadenceByMinute[minute]
                ))
            }
        }
        return result
    }

    private var cadenceValues: [Double] {
        buckets.compactMap(\.cadence)
    }

    private var averageCadence: Double? {
        average(cadenceValues)
    }

    private var fastestCadence: Double? {
        cadenceValues.max()
    }

    private var latestCadence: Double? {
        buckets.reversed().compactMap(\.cadence).first
    }

    var body: some View {
        AnalyticsCard(title: "步频") {
            if cadenceValues.isEmpty {
                Text("没有可用的步频数据")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                GeometryReader { geometry in
                    let axisWidth: CGFloat = 48
                    let plotWidth = max(80, geometry.size.width - axisWidth - 6)

                    HStack(spacing: 6) {
                        cadenceAxis

                        ZStack(alignment: .top) {
                            ScrollView(.horizontal) {
                                Chart {
                                    ForEach(buckets) { bucket in
                                        if let cadence = bucket.cadence {
                                            BarMark(
                                                x: .value("时间", displayIndex(bucket.index)),
                                                y: .value("步频", cadence),
                                                width: .fixed(7)
                                            )
                                            .foregroundStyle(healthOrange)
                                            .cornerRadius(3)
                                        }
                                    }

                                    if let averageCadence {
                                        RuleMark(y: .value("平均步频", averageCadence))
                                            .foregroundStyle(healthOrange)
                                            .lineStyle(StrokeStyle(lineWidth: 2.3, lineCap: .round))
                                    }
                                }
                                .chartXScale(domain: -0.5...(Double(max(visibleCount, buckets.count)) - 0.5))
                                .chartYScale(domain: 0...cadenceUpperBound)
                                .chartXAxis(.hidden)
                                .chartYAxis(.hidden)
                                .chartXSelection(value: $selectedChartIndex)
                                .frame(
                                    width: max(plotWidth, CGFloat(buckets.count) * barSlot),
                                    height: 210
                                )
                            }
                            .defaultScrollAnchor(.trailing)
                            .scrollIndicators(.hidden)

                            if let selectedBucket {
                                ChartTooltip(
                                    title: MetricFormatter.date(selectedBucket.workoutDate),
                                    value: MetricFormatter.cadence(selectedBucket.cadence),
                                    detail: "运动第 \(selectedBucket.elapsedMinute) 分钟"
                                )
                            }
                        }
                        .frame(width: plotWidth)
                    }
                }
                .frame(height: 210)

                Divider()
                summary
            }
        }
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 10) {
            metric(title: "平均步频", value: averageCadence)
            metric(title: "最快步频", value: fastestCadence)
            metric(title: "最近步频", value: latestCadence)
        }
    }

    private func metric(title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(MetricFormatter.cadence(value))
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cadenceUpperBound: Double {
        let maximum = cadenceValues.max() ?? 0
        return max(20, ceil(maximum / 20) * 20)
    }

    private var cadenceAxis: some View {
        let labels = [cadenceUpperBound, cadenceUpperBound / 2, 0]
        return VStack(alignment: .trailing, spacing: 0) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, value in
                Text("\(Int(value.rounded())) spm")
                    .font(.caption2)
                    .foregroundStyle(Color(.systemGray2))
                    .lineLimit(1)
                if index < labels.count - 1 {
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(width: 48, height: 190, alignment: .trailing)
    }

    private func displayIndex(_ index: Int) -> Int {
        buckets.count < visibleCount ? visibleCount - buckets.count + index : index
    }

    private var selectedBucket: CadenceBucket? {
        guard let selectedChartIndex else { return nil }
        let index = buckets.count < visibleCount
            ? selectedChartIndex - (visibleCount - buckets.count)
            : selectedChartIndex
        guard buckets.indices.contains(index) else { return nil }
        return buckets[index]
    }

    private func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
