import Charts
import SwiftUI
import UIKit

struct LatestRunVitalsCardView: View {
    let runs: [OutdoorRun]
    @EnvironmentObject private var store: HealthDataStore
    @State private var selectedElapsedSeconds: Double?
    @State private var elevationSamples: [ElevationTimelineSample] = []
    private let heartRateRed = Color.red
    private let paceBlue = Color(red: 0.505_882, green: 0.831_373, blue: 0.980_392)
    private let elevationGreen = Color(red: 0.133_333, green: 0.772_549, blue: 0.368_627)

    private struct ChartPoint: Identifiable {
        let sample: RunningTimelineSample
        let segment: Int

        var id: String { "\(segment)-\(sample.elapsedSeconds)" }
    }

    private struct ElevationChartPoint: Identifiable {
        let sample: ElevationTimelineSample
        let segment: Int

        var id: String { "elevation-\(segment)-\(sample.elapsedSeconds)" }
    }

    private var latestRun: OutdoorRun? {
        runs.max { $0.startDate < $1.startDate }
    }

    private var samples: [RunningTimelineSample] {
        latestRun?.runningTimelineData.sorted { $0.elapsedSeconds < $1.elapsedSeconds } ?? []
    }

    private var chartPoints: [ChartPoint] {
        let segments = HeartRateTimeline.segmentIndices(
            for: samples.map(\.elapsedSeconds)
        )
        return samples.indices.map { index in
            ChartPoint(sample: samples[index], segment: segments[index])
        }
    }

    private var elevationChartPoints: [ElevationChartPoint] {
        let segments = HeartRateTimeline.segmentIndices(
            for: elevationSamples.map(\.elapsedSeconds)
        )
        return elevationSamples.indices.map { index in
            ElevationChartPoint(sample: elevationSamples[index], segment: segments[index])
        }
    }

    var body: some View {
        AnalyticsCard(title: "最近一次跑步") {
            if samples.isEmpty {
                Text("最近一次跑步没有可同时显示的心率和配速数据")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                trendCharts
            }
        }
        .task(id: latestRun?.id) {
            elevationSamples = []
            guard let workoutID = latestRun?.id else { return }
            do {
                elevationSamples = ElevationTimeline.samplesForChart(
                    try await store.elevationData(for: workoutID)
                )
            } catch is CancellationError {
                return
            } catch {
                elevationSamples = []
            }
        }
    }

    private var trendCharts: some View {
        VStack(spacing: 12) {
            trendSection(
                title: "心率",
                value: heartRateText,
                color: heartRateRed
            ) {
                heartRateChart
            }

            trendSection(
                title: "配速",
                value: paceText,
                color: paceBlue
            ) {
                paceChart
            }

            trendSection(
                title: "海拔",
                value: elevationText,
                color: elevationGreen
            ) {
                elevationChart
            }
        }
    }

    private var heartRateChart: some View {
        Chart {
            ForEach(chartPoints) { point in
                LineMark(
                    x: .value("秒", point.sample.elapsedSeconds),
                    y: .value("标准化心率", normalizedHeartRate(point.sample.heartRateBPM)),
                    series: .value("心率分段", "heart-\(point.segment)")
                )
                .foregroundStyle(heartRateRed)
                .lineStyle(StrokeStyle(lineWidth: 2.3, lineCap: .round, lineJoin: .round))
            }

            selectionPoint(
                normalizedValue: selectedHeartRateBPM.map(normalizedHeartRate),
                color: heartRateRed
            )
        }
        .chartXScale(domain: 0...chartDuration)
        .chartYScale(domain: 0...1)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .modifier(
            SmoothChartSelectionModifier(
                selectedElapsedSeconds: $selectedElapsedSeconds,
                duration: chartDuration
            )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("心率")
        .accessibilityValue("时间 \(selectedTimeText)，心率 \(heartRateText)")
    }

    private var paceChart: some View {
        Chart {
            ForEach(chartPoints) { point in
                LineMark(
                    x: .value("秒", point.sample.elapsedSeconds),
                    y: .value("标准化配速", normalizedPace(point.sample.paceSecondsPerKilometer)),
                    series: .value("配速分段", "pace-\(point.segment)")
                )
                .foregroundStyle(paceBlue)
                .lineStyle(StrokeStyle(lineWidth: 2.3, lineCap: .round, lineJoin: .round))
            }

            selectionPoint(
                normalizedValue: selectedPaceSeconds.map(normalizedPace),
                color: paceBlue
            )
        }
        .chartXScale(domain: 0...chartDuration)
        .chartYScale(domain: 0...1)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .modifier(
            SmoothChartSelectionModifier(
                selectedElapsedSeconds: $selectedElapsedSeconds,
                duration: chartDuration
            )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("配速")
        .accessibilityValue("时间 \(selectedTimeText)，配速 \(paceText)")
    }

    private var elevationChart: some View {
        Chart {
            ForEach(elevationChartPoints) { point in
                LineMark(
                    x: .value("秒", point.sample.elapsedSeconds),
                    y: .value("标准化海拔", normalizedElevation(point.sample.meters)),
                    series: .value("海拔分段", "elevation-\(point.segment)")
                )
                .foregroundStyle(elevationGreen)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }

            selectionPoint(
                normalizedValue: selectedElevationMeters.map(normalizedElevation),
                color: elevationGreen
            )
        }
        .chartXScale(domain: 0...chartDuration)
        .chartYScale(domain: 0...1)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .modifier(
            SmoothChartSelectionModifier(
                selectedElapsedSeconds: $selectedElapsedSeconds,
                duration: chartDuration
            )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("海拔")
        .accessibilityValue("时间 \(selectedTimeText)，海拔 \(elevationText)")
    }

    @ChartContentBuilder
    private func selectionPoint(
        normalizedValue: Double?,
        color: Color
    ) -> some ChartContent {
        if let activeElapsedSeconds, let normalizedValue {
            PointMark(
                x: .value("所选时间", activeElapsedSeconds),
                y: .value("所选值", normalizedValue)
            )
            .foregroundStyle(color)
            .symbol {
                ZStack {
                    Circle()
                        .fill(Color(.systemBackground))
                        .frame(width: 12, height: 12)
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                }
            }
        }
    }

    private func trendSection<Content: View>(
        title: LocalizedStringResource,
        value: String,
        color: Color,
        @ViewBuilder chart: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(title)
                } icon: {
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                Spacer(minLength: 12)

                Text(value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(.secondaryLabel))
                    .monospacedDigit()
                    .lineLimit(1)
            }

            chart()
                .frame(height: 58)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chartDuration: TimeInterval {
        max(1, latestRun?.duration ?? 1)
    }

    private var heartRateMinimum: Double { samples.map(\.heartRateBPM).min() ?? 0 }
    private var heartRateMaximum: Double { samples.map(\.heartRateBPM).max() ?? 1 }
    private var paceMinimum: Double { samples.map(\.paceSecondsPerKilometer).min() ?? 0 }
    private var paceMaximum: Double { samples.map(\.paceSecondsPerKilometer).max() ?? 1 }

    private func normalizedHeartRate(_ value: Double) -> Double {
        normalized(value, minimum: heartRateMinimum, maximum: heartRateMaximum)
    }

    private func normalizedPace(_ value: Double) -> Double {
        normalized(value, minimum: paceMinimum, maximum: paceMaximum)
    }

    private func normalizedElevation(_ value: Double) -> Double {
        normalized(value, minimum: elevationMinimum, maximum: elevationMaximum)
    }

    private func normalized(_ value: Double, minimum: Double, maximum: Double) -> Double {
        guard maximum > minimum else { return 0.5 }
        return min(1, max(0, (value - minimum) / (maximum - minimum)))
    }

    private var heartRateText: String {
        guard let value = selectedHeartRateBPM else { return "—" }
        return "\(Int(value.rounded())) bpm"
    }

    private var paceText: String {
        MetricFormatter.pace(selectedPaceSeconds)
    }

    private var selectedTimeText: String {
        elapsedTime(Int((activeElapsedSeconds ?? 0).rounded()))
    }

    private var activeElapsedSeconds: Double? {
        guard let latestRun, !samples.isEmpty else { return nil }
        let elapsed = selectedElapsedSeconds ?? Double(samples.last?.elapsedSeconds ?? 0)
        return min(max(0, elapsed), latestRun.duration)
    }

    private var elevationText: String {
        guard let meters = selectedElevationMeters else { return "—" }
        return "\(Int(meters.rounded())) m"
    }

    private var elevationMinimum: Double { elevationSamples.map(\.meters).min() ?? 0 }
    private var elevationMaximum: Double { elevationSamples.map(\.meters).max() ?? 1 }

    private var selectedHeartRateBPM: Double? {
        interpolatedValue(
            at: activeElapsedSeconds,
            in: samples,
            elapsedSeconds: { Double($0.elapsedSeconds) },
            value: { $0.heartRateBPM }
        )
    }

    private var selectedPaceSeconds: Double? {
        interpolatedValue(
            at: activeElapsedSeconds,
            in: samples,
            elapsedSeconds: { Double($0.elapsedSeconds) },
            value: { $0.paceSecondsPerKilometer }
        )
    }

    private var selectedElevationMeters: Double? {
        interpolatedValue(
            at: activeElapsedSeconds,
            in: elevationSamples,
            elapsedSeconds: { Double($0.elapsedSeconds) },
            value: { $0.meters }
        )
    }

    private func interpolatedValue<Sample>(
        at elapsed: Double?,
        in values: [Sample],
        elapsedSeconds: (Sample) -> Double,
        value: (Sample) -> Double
    ) -> Double? {
        guard let elapsed, let first = values.first, let last = values.last else {
            return nil
        }
        if elapsed <= elapsedSeconds(first) { return value(first) }
        if elapsed >= elapsedSeconds(last) { return value(last) }

        var lowerIndex = 0
        var upperIndex = values.count - 1
        while upperIndex - lowerIndex > 1 {
            let middleIndex = (lowerIndex + upperIndex) / 2
            if elapsedSeconds(values[middleIndex]) <= elapsed {
                lowerIndex = middleIndex
            } else {
                upperIndex = middleIndex
            }
        }

        let lower = values[lowerIndex]
        let upper = values[upperIndex]
        let lowerTime = elapsedSeconds(lower)
        let upperTime = elapsedSeconds(upper)
        guard upperTime > lowerTime else { return value(lower) }
        let progress = (elapsed - lowerTime) / (upperTime - lowerTime)
        return value(lower) + (value(upper) - value(lower)) * progress
    }

    private func elapsedTime(_ seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        let remainder = max(0, seconds) % 60
        return "\(minutes):\(String(format: "%02d", remainder))"
    }
}

private struct SmoothChartSelectionModifier: ViewModifier {
    @Binding var selectedElapsedSeconds: Double?
    let duration: TimeInterval

    func body(content: Content) -> some View {
        content
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    HorizontalChartGestureView { locationX in
                        updateSelection(
                            atX: locationX,
                            proxy: proxy,
                            geometry: geometry
                        )
                    }
                }
            }
            .transaction { transaction in
                transaction.animation = nil
            }
    }

    private func updateSelection(
        atX locationX: CGFloat,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        guard let plotFrame = proxy.plotFrame else { return }
        let frame = geometry[plotFrame]
        let plotX = min(max(0, locationX - frame.minX), frame.width)
        guard let elapsed: Double = proxy.value(atX: plotX) else { return }
        selectedElapsedSeconds = min(max(0, elapsed), duration)
    }
}

private struct HorizontalChartGestureView: UIViewRepresentable {
    let onChanged: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChanged: onChanged)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        pan.cancelsTouchesInView = false
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onChanged = onChanged
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChanged: (CGFloat) -> Void

        init(onChanged: @escaping (CGFloat) -> Void) {
            self.onChanged = onChanged
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view,
                  gesture.state == .began || gesture.state == .changed else {
                return
            }
            onChanged(gesture.location(in: view).x)
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view, gesture.state == .ended else { return }
            onChanged(gesture.location(in: view).x)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = pan.view else {
                return true
            }
            let velocity = pan.velocity(in: view)
            return abs(velocity.x) > abs(velocity.y)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

struct CadenceCardView: View {
    let runs: [OutdoorRun]
    @State private var selectedChartIndex: Int?
    @State private var scrollPosition: Int
    private static let visibleCount = 20
    private let healthOrange = Color(red: 1, green: 0.29, blue: 0)

    private struct CadenceBucket: Identifiable {
        let id: String
        let index: Int
        let workoutID: UUID
        let workoutDate: Date
        let elapsedMinute: Int
        let cadence: Double
        let coverage: Double
    }

    private let buckets: [CadenceBucket]

    init(runs: [OutdoorRun]) {
        self.runs = runs
        let preparedBuckets = Self.makeBuckets(from: runs)
        buckets = preparedBuckets
        let initialPosition = preparedBuckets.count < Self.visibleCount
            ? Self.visibleCount - 1
            : max(0, preparedBuckets.count - 1)
        _scrollPosition = State(initialValue: initialPosition)
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
                    cadence: sample.stepsPerMinute,
                    coverage: sample.coverage
                ))
            }
        }
        return result
    }

    private var cadenceValues: [Double] {
        buckets.map(\.cadence)
    }

    private var averageCadence: Double? {
        weightedAverage(buckets.map { ($0.cadence, $0.coverage) })
    }

    private var fastestCadence: Double? {
        cadenceValues.max()
    }

    private var latestCadence: Double? {
        let runsWithCadence = runs.filter { !$0.minuteCadenceData.isEmpty }
        guard let latestRun = runsWithCadence.max(by: {
            $0.startDate < $1.startDate
        }) else { return nil }
        return weightedAverage(latestRun.minuteCadenceData.map {
            ($0.stepsPerMinute, $0.coverage)
        })
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
                            ForEach(visibleBuckets) { bucket in
                                BarMark(
                                    x: .value("时间", displayIndex(bucket.index)),
                                    y: .value("步频", bucket.cadence),
                                    width: .fixed(7)
                                )
                                .foregroundStyle(healthOrange)
                                .opacity(0.35 + 0.65 * bucket.coverage)
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
                        .chartXScale(domain: -0.5...(Double(max(Self.visibleCount, buckets.count)) - 0.5))
                        .chartYScale(domain: cadenceScaleLowerBound...cadenceUpperBound)
                        .chartXAxis(.hidden)
                        .chartYAxis(.hidden)
                        .chartScrollableAxes(.horizontal)
                        .chartXVisibleDomain(length: Self.visibleCount)
                        .chartScrollPosition(x: $scrollPosition)
                        .chartXSelection(value: $selectedChartIndex)
                        .frame(width: plotWidth, height: 210)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("步频图表")
                        .accessibilityValue("共 \(buckets.count) 个分钟数据点")
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
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) {
                cadenceMetrics
            }
            VStack(alignment: .leading, spacing: 10) {
                cadenceMetrics
            }
        }
    }

    @ViewBuilder
    private var cadenceMetrics: some View {
        metric(title: L10n.string("平均步频"), value: averageCadence)
        metric(title: L10n.string("最快步频"), value: fastestCadence)
        metric(
            title: selectedCadenceTitle,
            value: selectedBucket?.cadence ?? latestCadence
        )
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
        buckets.count < Self.visibleCount ? Self.visibleCount - buckets.count + index : index
    }

    private var selectedBucket: CadenceBucket? {
        guard let selectedChartIndex else { return nil }
        let index = buckets.count < Self.visibleCount
            ? selectedChartIndex - (Self.visibleCount - buckets.count)
            : selectedChartIndex
        guard buckets.indices.contains(index) else { return nil }
        return buckets[index]
    }

    private var visibleBuckets: [CadenceBucket] {
        guard buckets.count > Self.visibleCount else { return buckets }
        let range = ChartWindow.range(
            itemCount: buckets.count,
            visibleCount: Self.visibleCount,
            scrollPosition: scrollPosition,
            padding: 8
        )
        return Array(buckets[range])
    }

    private func weightedAverage(_ values: [(Double, Double)]) -> Double? {
        let totalWeight = values.reduce(0) { $0 + max(0, $1.1) }
        guard totalWeight > 0 else { return nil }
        return values.reduce(0) { $0 + $1.0 * max(0, $1.1) } / totalWeight
    }
}
