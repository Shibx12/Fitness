import Charts
import SwiftUI

struct RunningEfficiencyCardView: View {
    let runs: [OutdoorRun]
    @State private var selectedDate: Date?
    private let healthOrange = Color(red: 1, green: 0.29, blue: 0)

    private struct EfficiencyPoint: Identifiable {
        let run: OutdoorRun
        let value: Double

        var id: UUID { run.id }
        var date: Date { run.startDate }
    }

    private var points: [EfficiencyPoint] {
        runs.compactMap { run in
            guard run.runningEfficiency.status == .available,
                  let value = run.runningEfficiency.value else { return nil }
            return EfficiencyPoint(run: run, value: value)
        }
        .sorted { $0.date < $1.date }
    }

    var body: some View {
        AnalyticsCard(title: "跑步效率") {
            if points.isEmpty {
                Text("没有足够的心率和速度数据")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ZStack(alignment: .top) {
                    Chart(points) { point in
                        LineMark(
                            x: .value("日期", point.date),
                            y: .value("跑步效率", point.value)
                        )
                        .foregroundStyle(healthOrange)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                        PointMark(
                            x: .value("日期", point.date),
                            y: .value("跑步效率", point.value)
                        )
                        .foregroundStyle(healthOrange)
                        .symbolSize(48)
                    }
                    .chartYScale(domain: efficiencyDomain)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { value in
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(MetricFormatter.monthDay(date))
                                        .foregroundStyle(Color(.systemGray2))
                                }
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .trailing) { value in
                            AxisValueLabel {
                                if let efficiency = value.as(Double.self) {
                                    Text(String(format: "%.3f", efficiency))
                                        .font(.caption)
                                        .foregroundStyle(Color(.systemGray2))
                                }
                            }
                        }
                    }
                    .chartXSelection(value: $selectedDate)

                    if let selectedPoint {
                        ChartTooltip(
                            title: MetricFormatter.date(selectedPoint.date),
                            value: efficiency(selectedPoint.value),
                            detail: detail(for: selectedPoint.run.runningEfficiency)
                        )
                    }
                }
                .frame(height: 220)
            }
        }
    }

    private var selectedPoint: EfficiencyPoint? {
        guard let selectedDate else { return nil }
        return points.min {
            abs($0.date.timeIntervalSince(selectedDate))
                < abs($1.date.timeIntervalSince(selectedDate))
        }
    }

    private var efficiencyDomain: ClosedRange<Double> {
        guard let minimum = points.map(\.value).min(),
              let maximum = points.map(\.value).max() else { return 0...1 }
        let span = max(0.002, maximum - minimum)
        return max(0, minimum - span * 0.20)...(maximum + span * 0.20)
    }

    private func efficiency(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func detail(for value: RunningEfficiency) -> String {
        guard let speed = value.averageSpeedKilometersPerHour,
              let heartRate = value.averageHeartRateBPM else {
            return L10n.string("心率或速度数据不足")
        }
        return String(format: "%.1f km/h · %.0f bpm", speed, heartRate)
    }
}
