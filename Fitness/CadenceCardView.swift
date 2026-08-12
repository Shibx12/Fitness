import Charts
import SwiftUI

struct CadenceCardView: View {
    let runs: [OutdoorRun]
    @State private var selectedChartIndex: Int?
    private let visibleCount = 20
    private let healthOrange = Color(red: 1, green: 0.29, blue: 0)

    private struct CadenceBucket: Identifiable {
        let id: String
        let index: Int
        let workoutID: UUID
        let workoutDate: Date
        let elapsedMinute: Int
        let cadence: Double
    }

    private let buckets: [CadenceBucket]

    init(runs: [OutdoorRun]) {
        self.runs = runs
        buckets = Self.makeBuckets(from: runs)
    }

    private static func makeBuckets(from runs: [OutdoorRun]) -> [CadenceBucket] {
        var result: [CadenceBucket] = []

        for run in runs.sorted(by: { $0.startDate < $1.startDate }) {
            for sample in run.minuteCadenceData.sorted(by: { $0.elapsedMinute < $1.elapsedMinute }) {
                result.append(CadenceBucket(
                    id: sample.id,
                    index: result.count,
                    workoutID: run.id,
                    workoutDate: run.startDate,
                    elapsedMinute: sample.elapsedMinute,
                    cadence: sample.stepsPerMinute
                ))
            }
        }
        return result
    }

    private var cadenceValues: [Double] {
        buckets.map(\.cadence)
    }

    private var averageCadence: Double? {
        average(cadenceValues)
    }

    private var fastestCadence: Double? {
        cadenceValues.max()
    }

    private var latestCadence: Double? {
        let runsWithCadence = runs.filter { !$0.minuteCadenceData.isEmpty }
        guard let latestRun = runsWithCadence.max(by: {
            $0.startDate < $1.startDate
        }) else { return nil }
        return average(latestRun.minuteCadenceData.map(\.stepsPerMinute))
    }

    private var cadenceScaleLowerBound: Double {
        runEndMarkerCadence * 1.35
    }

    private var runEndMarkerCadence: Double {
        -max(8, cadenceUpperBound * 0.048)
    }

    private var lastCadenceBucketIDs: Set<String> {
        let grouped = Dictionary(grouping: buckets, by: \.workoutID)
        return Set(grouped.values.compactMap { workoutBuckets in
            workoutBuckets.max { $0.elapsedMinute < $1.elapsedMinute }?.id
        })
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

                        Chart {
                            ForEach(buckets) { bucket in
                                BarMark(
                                    x: .value("时间", displayIndex(bucket.index)),
                                    y: .value("步频", bucket.cadence),
                                    width: .fixed(7)
                                )
                                .foregroundStyle(healthOrange)
                                .cornerRadius(3)

                                if lastCadenceBucketIDs.contains(bucket.id) {
                                    PointMark(
                                        x: .value("时间", displayIndex(bucket.index)),
                                        y: .value("跑步结束", runEndMarkerCadence)
                                    )
                                    .foregroundStyle(healthOrange)
                                    .symbolSize(18)
                                    .accessibilityLabel("本次跑步的最后一个步频")
                                }
                            }

                            if let averageCadence {
                                RuleMark(y: .value("平均步频", averageCadence))
                                    .foregroundStyle(healthOrange)
                                    .lineStyle(StrokeStyle(lineWidth: 2.3, lineCap: .round))
                            }
                        }
                        .chartXScale(domain: -0.5...(Double(max(visibleCount, buckets.count)) - 0.5))
                        .chartYScale(domain: cadenceScaleLowerBound...cadenceUpperBound)
                        .chartXAxis(.hidden)
                        .chartYAxis(.hidden)
                        .chartScrollableAxes(.horizontal)
                        .chartXVisibleDomain(length: visibleCount)
                        .chartScrollPosition(initialX: displayIndex(buckets.count - 1))
                        .chartXSelection(value: $selectedChartIndex)
                        .frame(width: plotWidth, height: 210)
                    }
                }
                .frame(height: 210)

                Divider()
                    .padding(.top, -10)
                summary
            }
        }
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 10) {
            metric(title: L10n.string("平均步频"), value: averageCadence)
            metric(title: L10n.string("最快步频"), value: fastestCadence)
            metric(
                title: selectedCadenceTitle,
                value: selectedBucket?.cadence ?? latestCadence
            )
        }
    }

    private var selectedCadenceTitle: String {
        guard let selectedBucket else { return L10n.string("最近步频") }
        return L10n.string("\(MetricFormatter.monthDay(selectedBucket.workoutDate))步频")
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
