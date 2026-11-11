//
//  InsightsManager.swift
//  ZenNotch
//
//  Numbers for the Insights tab: completed and planned tasks per day (read from
//  Reminders, so the full history is there) and focused time (from the local log
//  the focus timer writes). Any range (7 days … all time) is computed from those
//  per-day totals, grouped into day, week, month or year bars.
//

import Defaults
import EventKit
import SwiftUI

/// "yyyy-MM-dd" key for a calendar day (local time).
func focusDayKey(_ date: Date) -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}

/// Parses a `focusDayKey` back into the start of that day.
private func dayFromFocusKey(_ key: String) -> Date? {
    let parts = key.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
}

enum InsightsRange: String, CaseIterable, Identifiable {
    case week, month, quarter, year, all
    var id: String { rawValue }

    /// Chip label.
    var chip: String {
        switch self {
        case .week: "7D"
        case .month: "30D"
        case .quarter: "3M"
        case .year: "1Y"
        case .all: "All"
        }
    }

    /// Summary card heading.
    var title: String {
        switch self {
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        case .quarter: "Last 3 months"
        case .year: "Last 12 months"
        case .all: "All time"
        }
    }

    /// "… up from 8 the ___ before."
    var previousPhrase: String {
        switch self {
        case .week: "week"
        case .month: "30 days"
        case .quarter: "3 months"
        case .year: "12 months"
        case .all: ""
        }
    }
}

/// What one bar covers.
enum InsightsBucketUnit { case day, week, month, year }

struct InsightsBucket: Identifiable, Equatable {
    /// First day covered.
    let start: Date
    /// Day after the last day covered (exclusive).
    let end: Date
    let unit: InsightsBucketUnit
    var completed = 0
    /// Reminders due in this bucket (done or not). Never below `completed`.
    var planned = 0
    var focusSeconds = 0
    var id: Date { start }

    var containsToday: Bool {
        let now = Date()
        return now >= start && now < end
    }
}

@MainActor
final class InsightsManager: ObservableObject {
    static let shared = InsightsManager()

    @Published var range: InsightsRange = .week { didSet { if range != oldValue { recompute() } } }

    /// Bars for the selected range, oldest first.
    @Published private(set) var buckets: [InsightsBucket] = []
    @Published private(set) var unit: InsightsBucketUnit = .day

    // Totals for the selected range.
    @Published private(set) var completed = 0
    @Published private(set) var planned = 0
    @Published private(set) var focusSeconds = 0
    @Published private(set) var activeDays = 0
    @Published private(set) var totalDays = 0
    /// Completed in the same-length period just before (nil for All time).
    @Published private(set) var previousCompleted: Int?
    /// First day of the selected range.
    @Published private(set) var rangeStart = Date()
    @Published private(set) var hasReminderAccess: Bool

    var bestBucket: InsightsBucket? {
        buckets.filter { $0.completed > 0 }.max { $0.completed < $1.completed }
    }

    private let store = EKEventStore()
    private let cal = Calendar.current
    private var observers: [NSObjectProtocol] = []
    private var focusObserver: Defaults.Observation?
    private var loadTask: Task<Void, Never>?

    // Per-day totals from Reminders (start of day → count).
    private var completedByDay: [Date: Int] = [:]
    private var plannedByDay: [Date: Int] = [:]

    private init() {
        hasReminderAccess = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        observers.append(NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.reload() } })
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.recompute() } })
        // Focus time is local, so a new focus entry only needs a recompute (no fetch).
        focusObserver = Defaults.observe(.focusDaily) { [weak self] _ in
            Task { @MainActor in self?.recompute() }
        }
        reload()
    }

    // MARK: Loading

    /// Re-reads Reminders (whole history), then recomputes the current range.
    func reload() {
        loadTask?.cancel()
        loadTask = Task { @MainActor in await load() }
    }

    private struct ReminderFacts: Sendable {
        let dueDay: Date?
        let completionDay: Date?
    }

    private func load() async {
        hasReminderAccess = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        guard hasReminderAccess else {
            completedByDay = [:]
            plannedByDay = [:]
            recompute()
            return
        }
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
        let calendars = visibleCalendars()
        async let done = fetch(store.predicateForCompletedReminders(
            withCompletionDateStarting: nil, ending: tomorrow, calendars: calendars))
        async let open = fetch(store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: tomorrow, calendars: calendars))
        let (doneFacts, openFacts) = await (done, open)
        guard !Task.isCancelled else { return }

        var completed: [Date: Int] = [:]
        var planned: [Date: Int] = [:]
        for fact in doneFacts {
            if let day = fact.completionDay { completed[day, default: 0] += 1 }
            if let due = fact.dueDay, due < tomorrow { planned[due, default: 0] += 1 }
        }
        for fact in openFacts {
            if let due = fact.dueDay, due < tomorrow { planned[due, default: 0] += 1 }
        }
        completedByDay = completed
        plannedByDay = planned
        recompute()
    }

    // MARK: Ranges

    private func recompute() {
        let today = cal.startOfDay(for: Date())
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: today) else { return }

        var focusByDay: [Date: Int] = [:]
        for (key, seconds) in Defaults[.focusDaily] {
            if let day = dayFromFocusKey(key) { focusByDay[day, default: 0] += seconds }
        }
        focusByDay[today, default: 0] += FocusTimerManager.shared.unloggedSecondsToday

        let (start, unit) = window(for: range, today: today, focusDays: focusByDay.keys)
        let starts = bucketStarts(from: start, until: tomorrow, unit: unit)

        var bars: [InsightsBucket] = starts.enumerated().map { i, s in
            let end = i + 1 < starts.count ? starts[i + 1] : tomorrow
            return InsightsBucket(start: s, end: end, unit: unit)
        }

        var active = 0
        var day = start
        var index = 0
        while day < tomorrow {
            while index + 1 < bars.count && day >= bars[index].end { index += 1 }
            let done = completedByDay[day] ?? 0
            let seconds = focusByDay[day] ?? 0
            bars[index].completed += done
            bars[index].planned += max(plannedByDay[day] ?? 0, done)
            bars[index].focusSeconds += seconds
            if done > 0 || seconds >= 60 { active += 1 }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        // Same-length period just before, for the comparison line.
        var previous: Int?
        if range != .all {
            let length = cal.dateComponents([.day], from: start, to: tomorrow).day ?? 0
            if let prevStart = cal.date(byAdding: .day, value: -length, to: start) {
                previous = completedByDay.reduce(0) { sum, entry in
                    entry.key >= prevStart && entry.key < start ? sum + entry.value : sum
                }
            }
        }

        self.unit = unit
        self.rangeStart = start
        self.buckets = bars
        self.completed = bars.reduce(0) { $0 + $1.completed }
        self.planned = bars.reduce(0) { $0 + $1.planned }
        self.focusSeconds = bars.reduce(0) { $0 + $1.focusSeconds }
        self.activeDays = active
        self.totalDays = cal.dateComponents([.day], from: start, to: tomorrow).day ?? 0
        self.previousCompleted = previous
    }

    /// First day of the range and the bar size.
    private func window(for range: InsightsRange, today: Date,
                        focusDays: Dictionary<Date, Int>.Keys) -> (Date, InsightsBucketUnit) {
        func daysBack(_ n: Int) -> Date { cal.date(byAdding: .day, value: -n, to: today) ?? today }
        func startOf(_ component: Calendar.Component, _ date: Date) -> Date {
            cal.dateInterval(of: component, for: date)?.start ?? date
        }
        switch range {
        case .week:
            return (daysBack(6), .day)
        case .month:
            return (daysBack(29), .day)
        case .quarter:
            let thisWeek = startOf(.weekOfYear, today)
            return (cal.date(byAdding: .weekOfYear, value: -12, to: thisWeek) ?? thisWeek, .week)
        case .year:
            let thisMonth = startOf(.month, today)
            return (cal.date(byAdding: .month, value: -11, to: thisMonth) ?? thisMonth, .month)
        case .all:
            // From the first completed task or focus session (planned-only days don't
            // count, so a years-old overdue reminder doesn't stretch the chart).
            let first = (Array(completedByDay.keys) + Array(focusDays)).min()
                ?? plannedByDay.keys.min() ?? today
            let thisMonth = startOf(.month, today)
            // Show at least 6 months so a new install isn't a single fat bar.
            let minimum = cal.date(byAdding: .month, value: -5, to: thisMonth) ?? thisMonth
            let firstMonth = min(startOf(.month, first), minimum)
            let months = cal.dateComponents([.month], from: firstMonth, to: thisMonth).month ?? 0
            if months >= 24 { return (startOf(.year, first), .year) }
            return (firstMonth, .month)
        }
    }

    private func bucketStarts(from start: Date, until end: Date, unit: InsightsBucketUnit) -> [Date] {
        let component: Calendar.Component = switch unit {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
        var starts: [Date] = []
        var current = start
        while current < end {
            starts.append(current)
            guard let next = cal.date(byAdding: component, value: 1, to: current) else { break }
            current = next
        }
        return starts
    }

    /// Respects the reminder lists chosen in Settings > Calendar (same as the tasks card).
    private func visibleCalendars() -> [EKCalendar]? {
        let all = store.calendars(for: .reminder)
        if case .selected(let ids) = Defaults[.calendarSelectionState] {
            return all.filter { ids.contains($0.calendarIdentifier) }
        }
        return all
    }

    private func fetch(_ predicate: NSPredicate) async -> [ReminderFacts] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let cal = Calendar.current
                let facts = (reminders ?? []).map { r -> ReminderFacts in
                    let due = r.dueDateComponents.flatMap { cal.date(from: $0) }.map { cal.startOfDay(for: $0) }
                    return ReminderFacts(dueDay: due, completionDay: r.completionDate.map { cal.startOfDay(for: $0) })
                }
                continuation.resume(returning: facts)
            }
        }
    }
}

/// "7h 50m", "45m", "0m".
func focusDurationLabel(_ seconds: Int) -> String {
    let minutes = seconds / 60
    let h = minutes / 60, m = minutes % 60
    if h == 0 { return "\(m)m" }
    return m == 0 ? "\(h)h" : "\(h)h \(m)m"
}
