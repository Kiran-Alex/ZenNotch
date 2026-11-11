//
//  InsightsManager.swift
//  ZenNotch
//
//  Numbers for the Insights tab: per-day completed and planned tasks (read from
//  Reminders, so past days are included) and focused time (from the local log
//  the focus timer writes). Covers the last 7 days plus the 7 before, to compare.
//

import Defaults
import EventKit
import SwiftUI

/// "yyyy-MM-dd" key for a calendar day (local time).
func focusDayKey(_ date: Date) -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}

struct DayStat: Identifiable, Equatable {
    let day: Date
    var completed: Int
    /// Reminders due that day (done or not). Never below `completed`.
    var planned: Int
    var focusSeconds: Int
    var id: Date { day }
    var isActive: Bool { completed > 0 || focusSeconds >= 60 }
}

@MainActor
final class InsightsManager: ObservableObject {
    static let shared = InsightsManager()

    /// Last 7 days, oldest first (today is last).
    @Published private(set) var days: [DayStat] = []
    /// The 7 days before those.
    @Published private(set) var previousDays: [DayStat] = []
    @Published private(set) var hasReminderAccess: Bool

    private let store = EKEventStore()
    private let cal = Calendar.current
    private var observers: [NSObjectProtocol] = []
    private var focusObserver: Defaults.Observation?
    private var loadTask: Task<Void, Never>?

    private init() {
        hasReminderAccess = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        observers.append(NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.reload() } })
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.reload() } })
        focusObserver = Defaults.observe(.focusDaily) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        reload()
    }

    // MARK: Week summary

    var completedThisWeek: Int { days.reduce(0) { $0 + $1.completed } }
    var plannedThisWeek: Int { days.reduce(0) { $0 + $1.planned } }
    var completedLastWeek: Int { previousDays.reduce(0) { $0 + $1.completed } }
    var focusThisWeek: Int { days.reduce(0) { $0 + $1.focusSeconds } }
    var activeDays: Int { days.filter(\.isActive).count }
    var bestDay: DayStat? {
        days.filter { $0.completed > 0 }.max { $0.completed < $1.completed }
    }

    // MARK: Loading

    func reload() {
        loadTask?.cancel()
        loadTask = Task { @MainActor in await load() }
    }

    private struct ReminderFacts: Sendable {
        let dueDay: Date?
        let completionDate: Date?
    }

    private func load() async {
        hasReminderAccess = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        let today = cal.startOfDay(for: Date())
        guard let rangeStart = cal.date(byAdding: .day, value: -13, to: today),
              let rangeEnd = cal.date(byAdding: .day, value: 1, to: today) else { return }

        var completedByDay: [Date: Int] = [:]
        var plannedByDay: [Date: Int] = [:]

        if hasReminderAccess {
            let calendars = visibleCalendars()
            // Completed in range (also counts toward "planned" on their due day).
            // Look back a little further so tasks finished late still count as planned.
            let completedFrom = cal.date(byAdding: .day, value: -30, to: rangeStart) ?? rangeStart
            async let done = fetch(store.predicateForCompletedReminders(
                withCompletionDateStarting: completedFrom, ending: rangeEnd, calendars: calendars))
            async let open = fetch(store.predicateForIncompleteReminders(
                withDueDateStarting: rangeStart, ending: rangeEnd, calendars: calendars))
            let (doneFacts, openFacts) = await (done, open)
            guard !Task.isCancelled else { return }

            for fact in doneFacts {
                if let completed = fact.completionDate, completed >= rangeStart, completed < rangeEnd {
                    completedByDay[cal.startOfDay(for: completed), default: 0] += 1
                }
                if let due = fact.dueDay, due >= rangeStart, due < rangeEnd {
                    plannedByDay[due, default: 0] += 1
                }
            }
            for fact in openFacts {
                if let due = fact.dueDay, due >= rangeStart, due < rangeEnd {
                    plannedByDay[due, default: 0] += 1
                }
            }
        }

        let focus = Defaults[.focusDaily]
        let live = FocusTimerManager.shared.unloggedSecondsToday
        let all: [DayStat] = (0..<14).compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: offset, to: rangeStart) else { return nil }
            let completed = completedByDay[day] ?? 0
            var seconds = focus[focusDayKey(day)] ?? 0
            if day == today { seconds += live }
            return DayStat(day: day, completed: completed,
                           planned: max(plannedByDay[day] ?? 0, completed),
                           focusSeconds: seconds)
        }
        previousDays = Array(all.prefix(7))
        days = Array(all.suffix(7))
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
                    return ReminderFacts(dueDay: due, completionDate: r.completionDate)
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
