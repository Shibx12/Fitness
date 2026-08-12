import SwiftUI

struct AnalyticsCard<Content: View>: View {
    let title: LocalizedStringResource
    let content: Content

    init(title: LocalizedStringResource, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.bold())
            content
        }
        .padding(20)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
    }
}

enum MetricFormatter {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .autoupdatingCurrent
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    static func pace(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "—" }
        let rounded = Int(seconds.rounded())
        return "\(rounded / 60):\(String(format: "%02d", rounded % 60)) /km"
    }

    static func cadence(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(Int(value.rounded())) spm"
    }

    static func date(_ date: Date) -> String {
        date.formatted(
            .dateTime.year().month(.wide).day().locale(.autoupdatingCurrent)
        )
    }

    static func monthDay(_ date: Date) -> String {
        date.formatted(
            .dateTime.month(.wide).day().locale(.autoupdatingCurrent)
        )
    }

    static func monthDayWeekday(_ date: Date) -> String {
        date.formatted(
            .dateTime.month(.wide).day().weekday(.wide).locale(.autoupdatingCurrent)
        )
    }

    static func monthDayWeekdayTime(_ date: Date) -> String {
        date.formatted(
            .dateTime
                .month(.wide)
                .day()
                .weekday(.abbreviated)
                .hour(.twoDigits(amPM: .abbreviated))
                .minute(.twoDigits)
                .locale(.autoupdatingCurrent)
        )
    }

    static func dateRange(workoutIDs: [UUID], dates: [UUID: Date]) -> String {
        let values = workoutIDs.compactMap { dates[$0] }.sorted()
        guard let first = values.first, let last = values.last else {
            return L10n.string("日期未知")
        }
        if Calendar.current.isDate(first, inSameDayAs: last) {
            return date(first)
        }
        return "\(date(first))–\(date(last))"
    }
}

struct ChartTooltip: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text(value)
                .font(.caption.monospacedDigit())
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        .allowsHitTesting(false)
    }
}
