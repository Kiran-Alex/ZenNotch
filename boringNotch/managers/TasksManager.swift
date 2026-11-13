//
//  TasksManager.swift
//  ZenNotch
//
//  Two-way sync between the notch tasks panel and Apple Reminders (EventKit).
//  EventKit is the single source of truth: every edit is written straight to
//  Reminders, and any change made elsewhere (Reminders app, iCloud, other
//  devices) arrives via `.EKEventStoreChanged` and triggers a reload.
//

import AppKit
import Defaults
import EventKit
import SwiftUI

// MARK: - Model

enum TaskPriority: Int, CaseIterable, Identifiable {
    case none, low, medium, high

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    /// EventKit uses 1–4 = high, 5 = medium, 6–9 = low, 0 = none.
    init(ekPriority: Int) {
        switch ekPriority {
        case 1...4: self = .high
        case 5: self = .medium
        case 6...9: self = .low
        default: self = .none
        }
    }

    var ekPriority: Int {
        switch self {
        case .none: return 0
        case .low: return 9
        case .medium: return 5
        case .high: return 1
        }
    }
}

struct TaskList: Identifiable, Hashable {
    let id: String
    let title: String
}

/// Value snapshot of an `EKReminder`, safe to hand to SwiftUI.
struct TaskItem: Identifiable, Equatable {
    let id: String
    let title: String
    let isCompleted: Bool
    let completionDate: Date?
    let priority: TaskPriority
    let listID: String
    let listName: String
    /// Start of the due day, if the reminder has a due date.
    let dueDay: Date?
    /// Exact due time, only when the reminder has a time (not all-day).
    let dueTime: Date?
    let repeatSummary: String?
    let location: String?
}

// MARK: - Manager

@MainActor
final class TasksManager: ObservableObject {
    static let shared = TasksManager()

    @Published private(set) var todo: [TaskItem] = []
    @Published private(set) var completed: [TaskItem] = []
    @Published private(set) var lists: [TaskList] = []
    /// Start-of-day dates that have at least one open task (for calendar dots).
    @Published private(set) var daysWithTasks: Set<Date> = []
    /// The list new reminders go into; its name is hidden on rows as it adds no info.
    @Published private(set) var defaultListID: String?
    /// Planned minutes per task (local; see `Defaults.Keys.taskDurations`).
    @Published private(set) var plannedMinutes: [String: Int] = Defaults[.taskDurations]
    @Published private(set) var authorizationStatus: EKAuthorizationStatus
    @Published var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    /// A timed task that just came due; the closed notch shows it as a live activity.
    @Published private(set) var dueAlert: TaskItem?

    private let store = EKEventStore()
    private var alertTimer: Timer?
    private var alertClearTask: Task<Void, Never>?
    private var alertScanTask: Task<Void, Never>?
    /// "<id>@<due time>" keys already announced this run, so each due time alerts once.
    private var announcedAlerts: Set<String> = []
    private let calendar = Calendar.current
    private var changeObserver: NSObjectProtocol?
    private var dayChangeObserver: NSObjectProtocol?
    private var reloadTask: Task<Void, Never>?

    private init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .reminder)

        // Changes from any source (this app, Reminders app, iCloud sync).
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        // Roll "today" over at midnight.
        dayChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.selectedDate = self.calendar.startOfDay(for: Date())
                self.reload()
            }
        }
        reload()
    }

    var hasAccess: Bool { authorizationStatus == .fullAccess }

    var isShowingToday: Bool { calendar.isDateInToday(selectedDate) }

    // MARK: Access

    func requestAccess() async {
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        if granted {
            // EventKit can keep reporting the old status for the rest of this run, and an
            // existing store won't see data until it's reset. Trust the grant instead.
            Self.grantedThisRun = true
            store.reset()
            authorizationStatus = .fullAccess
            reload()
            InsightsManager.shared.reload()
        } else {
            authorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
        }
    }

    /// Set once the user grants access in this run (see `requestAccess`).
    static private(set) var grantedThisRun = false

    /// Current Reminders status, without letting a stale "not determined" undo a grant.
    static func currentStatus() -> EKAuthorizationStatus {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        return grantedThisRun && status == .notDetermined ? .fullAccess : status
    }

    // MARK: Date navigation

    func shiftDay(by days: Int) {
        guard let next = calendar.date(byAdding: .day, value: days, to: selectedDate) else { return }
        selectedDate = calendar.startOfDay(for: next)
        reload()
    }

    func goToToday() {
        go(to: Date())
    }

    func go(to date: Date) {
        selectedDate = calendar.startOfDay(for: date)
        reload()
    }

    // MARK: Loading

    /// Re-reads reminders for `selectedDate`. Coalesces bursts of change notifications.
    func reload() {
        #if DEBUG
        if DebugMock.active { return }
        #endif
        scheduleDueAlerts()
        authorizationStatus = Self.currentStatus()
        guard hasAccess else {
            todo = []; completed = []; lists = []; daysWithTasks = []
            return
        }

        reloadTask?.cancel()
        reloadTask = Task { @MainActor in
            let calendars = visibleCalendars()
            defaultListID = store.defaultCalendarForNewReminders()?.calendarIdentifier
            lists = store.calendars(for: .reminder)
                .map { TaskList(id: $0.calendarIdentifier, title: $0.title) }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

            let dayStart = selectedDate
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!

            async let open = fetch(store.predicateForIncompleteReminders(
                withDueDateStarting: nil, ending: nil, calendars: calendars))
            async let done = fetch(store.predicateForCompletedReminders(
                withCompletionDateStarting: dayStart, ending: dayEnd, calendars: calendars))
            let (openItems, doneItems) = await (open, done)
            guard !Task.isCancelled else { return }
            #if DEBUG
            if DebugMock.active { return }
            #endif

            let showingToday = isShowingToday
            let defaultSorted = openItems
                .filter { item in
                    guard let due = item.dueDay else { return showingToday } // undated → today only
                    return showingToday ? due < dayEnd : (due >= dayStart && due < dayEnd)
                }
                .sorted(by: Self.todoOrder)
            let newTodo = applyCustomOrder(defaultSorted)
            pruneCustomOrder()
            let newCompleted = doneItems.sorted {
                ($0.completionDate ?? .distantPast) > ($1.completionDate ?? .distantPast)
            }
            daysWithTasks = Set(openItems.compactMap(\.dueDay))
            withAnimation(.smooth(duration: 0.3)) {
                todo = newTodo
                completed = newCompleted
            }
        }
    }

    // MARK: Manual order (local)

    /// Tasks the user has placed keep their saved position; tasks never placed
    /// (e.g. just added) go on top in the default order, so they're easy to see.
    private func applyCustomOrder(_ items: [TaskItem]) -> [TaskItem] {
        var rank: [String: Int] = [:]
        for (index, id) in Defaults[.taskOrder].enumerated() where rank[id] == nil {
            rank[id] = index
        }
        guard !rank.isEmpty else { return items }
        let unplaced = items.filter { rank[$0.id] == nil }
        let placed = items.filter { rank[$0.id] != nil }.sorted { rank[$0.id]! < rank[$1.id]! }
        return unplaced + placed
    }

    // MARK: Planned duration (local)

    func setPlannedMinutes(_ id: String, _ minutes: Int?) {
        if let minutes, minutes > 0 { plannedMinutes[id] = min(minutes, 600) } else { plannedMinutes[id] = nil }
        Defaults[.taskDurations] = plannedMinutes
        FocusTimerManager.shared.plannedDurationChanged(for: id)
    }

    /// Drops ids of reminders that were deleted or completed, so the list can't grow forever.
    private func pruneCustomOrder() {
        let durations = plannedMinutes.filter { id, _ in
            (store.calendarItem(withIdentifier: id) as? EKReminder)?.isCompleted == false
        }
        if durations.count != plannedMinutes.count {
            plannedMinutes = durations
            Defaults[.taskDurations] = durations
        }

        let order = Defaults[.taskOrder]
        guard !order.isEmpty else { return }
        let kept = order.filter { id in
            guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return false }
            return !reminder.isCompleted
        }
        if kept.count != order.count { Defaults[.taskOrder] = kept }
    }

    /// Moves an open task to a new position in the visible list and saves the order.
    func moveTask(id: String, toIndex newIndex: Int) {
        guard let from = todo.firstIndex(where: { $0.id == id }),
              todo.indices.contains(newIndex), from != newIndex else { return }
        var items = todo
        let item = items.remove(at: from)
        items.insert(item, at: newIndex)
        todo = items

        let shown = items.map(\.id)
        let shownSet = Set(shown)
        // Tasks from other days keep their relative order after the visible ones.
        Defaults[.taskOrder] = shown + Defaults[.taskOrder].filter { !shownSet.contains($0) }
    }

    /// Respects the reminder lists chosen in Settings > Calendar.
    private func visibleCalendars() -> [EKCalendar]? {
        let all = store.calendars(for: .reminder)
        if case .selected(let ids) = Defaults[.calendarSelectionState] {
            return all.filter { ids.contains($0.calendarIdentifier) }
        }
        return all
    }

    private func fetch(_ predicate: NSPredicate) async -> [TaskItem] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                // Convert inside the callback so no EKReminder escapes this thread.
                let items = (reminders ?? []).map { Self.makeItem(from: $0) }
                continuation.resume(returning: items)
            }
        }
    }

    /// Overdue/earliest first, then priority, then title; undated last.
    nonisolated private static func todoOrder(_ a: TaskItem, _ b: TaskItem) -> Bool {
        switch (a.dueTime ?? a.dueDay, b.dueTime ?? b.dueDay) {
        case let (x?, y?) where x != y: return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default:
            if a.priority != b.priority { return a.priority.rawValue > b.priority.rawValue }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    nonisolated private static func makeItem(from reminder: EKReminder) -> TaskItem {
        let cal = Calendar.current
        var dueDay: Date?
        var dueTime: Date?
        if let comps = reminder.dueDateComponents, let date = cal.date(from: comps) {
            dueDay = cal.startOfDay(for: date)
            if comps.hour != nil { dueTime = date }
        }
        if dueTime == nil, let alarmDate = reminder.alarms?.compactMap(\.absoluteDate).first {
            dueTime = alarmDate
        }
        let location = reminder.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        return TaskItem(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "",
            isCompleted: reminder.isCompleted,
            completionDate: reminder.completionDate,
            priority: TaskPriority(ekPriority: reminder.priority),
            listID: reminder.calendar?.calendarIdentifier ?? "",
            listName: reminder.calendar?.title ?? "",
            dueDay: dueDay,
            dueTime: dueTime,
            repeatSummary: reminder.recurrenceRules?.first.map(repeatSummary(for:)),
            location: (location?.isEmpty ?? true) ? nil : location
        )
    }

    nonisolated private static func repeatSummary(for rule: EKRecurrenceRule) -> String {
        let weekdays: Set<EKWeekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
        let days = Set(rule.daysOfTheWeek?.map(\.dayOfTheWeek) ?? [])
        if rule.frequency == .weekly, rule.interval == 1, days == weekdays { return "Weekdays" }
        if rule.frequency == .weekly, rule.interval == 1, days == [.saturday, .sunday] { return "Weekends" }
        let unit: String
        switch rule.frequency {
        case .daily: unit = "day"
        case .weekly: unit = "week"
        case .monthly: unit = "month"
        case .yearly: unit = "year"
        @unknown default: unit = "time"
        }
        if rule.interval <= 1 {
            switch rule.frequency {
            case .daily: return "Daily"
            case .weekly: return "Weekly"
            case .monthly: return "Monthly"
            case .yearly: return "Yearly"
            @unknown default: return "Repeats"
            }
        }
        return "Every \(rule.interval) \(unit)s"
    }

    // MARK: Writing (all changes go straight to Reminders)

    private func reminder(_ item: TaskItem) -> EKReminder? {
        store.calendarItem(withIdentifier: item.id) as? EKReminder
    }

    private func save(_ reminder: EKReminder) {
        do {
            try store.save(reminder, commit: true)
        } catch {
            NSLog("TasksManager: failed to save reminder: \(error.localizedDescription)")
        }
        reload()
    }

    struct AddedTask {
        let id: String
        let listName: String
        let isDefaultList: Bool
        let dueDay: Date
    }

    /// Creates the reminder and returns details for UI feedback.
    /// `due` comes from natural-language parsing; without it the task is due on
    /// the selected day (date only), so it shows up where it was added.
    @discardableResult
    func addTask(title: String, due: ParsedDue? = nil, minutes: Int? = nil,
                 priority: TaskPriority? = nil, listID: String? = nil) -> AddedTask? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultList = store.defaultCalendarForNewReminders()
        // "#Work" picks the list; otherwise the default list for new reminders.
        let chosen = listID.flatMap { store.calendar(withIdentifier: $0) }
        guard hasAccess, !trimmed.isEmpty,
              let list = chosen ?? defaultList ?? store.calendars(for: .reminder).first
        else { return nil }
        let reminder = EKReminder(eventStore: store)
        reminder.title = trimmed
        reminder.calendar = list
        if let priority { reminder.priority = priority.ekPriority }

        let dueDate = due?.date ?? selectedDate
        if due?.hasTime == true {
            applyDue(calendar.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate), to: reminder)
        } else {
            reminder.dueDateComponents = calendar.dateComponents([.year, .month, .day], from: dueDate)
        }
        save(reminder)
        if let minutes { setPlannedMinutes(reminder.calendarItemIdentifier, minutes) }
        return AddedTask(
            id: reminder.calendarItemIdentifier,
            listName: list.title,
            isDefaultList: list.calendarIdentifier == defaultList?.calendarIdentifier,
            dueDay: calendar.startOfDay(for: dueDate)
        )
    }

    func setCompleted(_ item: TaskItem, _ completed: Bool) {
        guard let reminder = reminder(item) else { return }
        reminder.isCompleted = completed
        save(reminder)
    }

    func rename(_ item: TaskItem, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.title, let reminder = reminder(item) else { return }
        reminder.title = trimmed
        save(reminder)
    }

    func setPriority(_ item: TaskItem, _ priority: TaskPriority) {
        guard let reminder = reminder(item) else { return }
        reminder.priority = priority.ekPriority
        save(reminder)
    }

    func move(_ item: TaskItem, toListID listID: String) {
        guard let reminder = reminder(item),
              let list = store.calendar(withIdentifier: listID) else { return }
        reminder.calendar = list
        save(reminder)
    }

    /// Moves the due date to another day, keeping any time of day.
    func setDueDay(_ item: TaskItem, _ day: Date?) {
        guard let reminder = reminder(item) else { return }
        guard let day else {
            reminder.dueDateComponents = nil
            reminder.alarms?.forEach { reminder.removeAlarm($0) }
            save(reminder)
            return
        }
        var comps = calendar.dateComponents([.year, .month, .day], from: day)
        if let time = item.dueTime {
            let t = calendar.dateComponents([.hour, .minute], from: time)
            comps.hour = t.hour
            comps.minute = t.minute
        }
        applyDue(comps, to: reminder)
        save(reminder)
    }

    /// Sets (or clears, with nil) a time of day; adds an alarm so Reminders notifies.
    func setDueTime(_ item: TaskItem, hour: Int?, minute: Int = 0) {
        guard let reminder = reminder(item) else { return }
        var comps = calendar.dateComponents([.year, .month, .day], from: item.dueDay ?? selectedDate)
        if let hour {
            comps.hour = hour
            comps.minute = minute
        }
        applyDue(comps, to: reminder)
        save(reminder)
    }

    private func applyDue(_ comps: DateComponents, to reminder: EKReminder) {
        reminder.dueDateComponents = comps
        reminder.alarms?.forEach { reminder.removeAlarm($0) }
        if comps.hour != nil, let date = calendar.date(from: comps) {
            reminder.addAlarm(EKAlarm(absoluteDate: date))
        }
    }

    func delete(_ item: TaskItem) {
        guard let reminder = reminder(item) else { return }
        do {
            try store.remove(reminder, commit: true)
        } catch {
            NSLog("TasksManager: failed to delete reminder: \(error.localizedDescription)")
        }
        reload()
    }
}

// MARK: - Due alerts

extension TasksManager {
    /// How long the due alert stays on the closed notch.
    static let dueAlertDuration: Duration = .seconds(60)
    /// If the alert would fire later than this (e.g. the Mac was asleep), it's skipped.
    private static let dueAlertGrace: TimeInterval = 5 * 60
    /// Id of the sample alert from `debugShowDueAlert`; it isn't in Reminders.
    private static let debugAlertID = "debug-alert"

    private func alertKey(_ item: TaskItem) -> String? {
        guard let due = item.dueTime else { return nil }
        return "\(item.id)@\(Int(due.timeIntervalSince1970))"
    }

    /// Finds the next timed, open task and arms a timer for its due time. Runs on every
    /// reload, so edits, completions and syncs from other devices re-arm it.
    func scheduleDueAlerts() {
        alertScanTask?.cancel()
        guard Self.currentStatus() == .fullAccess else {
            alertTimer?.invalidate()
            alertTimer = nil
            dismissDueAlert()
            return
        }
        alertScanTask = Task { @MainActor in
            let now = Date()
            let earliest = now.addingTimeInterval(-Self.dueAlertGrace)
            let dayStart = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: 2, to: dayStart)!
            let open = await fetch(store.predicateForIncompleteReminders(
                withDueDateStarting: dayStart, ending: end, calendars: visibleCalendars()))
            guard !Task.isCancelled else { return }

            // Drop the current alert if its task was completed, deleted or rescheduled.
            if let current = dueAlert, current.id != Self.debugAlertID,
               !open.contains(where: { alertKey($0) == alertKey(current) }) {
                dismissDueAlert()
            }
            let pending = open
                .filter { item in
                    guard let due = item.dueTime, let key = alertKey(item) else { return false }
                    return due >= earliest && !announcedAlerts.contains(key)
                }
                .sorted { $0.dueTime! < $1.dueTime! }

            alertTimer?.invalidate()
            alertTimer = nil
            guard let next = pending.first, let due = next.dueTime else { return }
            if due <= now {
                fireDueAlert(next)
            } else {
                // Re-scan at the due time rather than firing blindly, so the task is re-checked.
                let timer = Timer(fire: due, interval: 0, repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.scheduleDueAlerts() }
                }
                RunLoop.main.add(timer, forMode: .common)
                alertTimer = timer
            }
        }
    }

    private func fireDueAlert(_ item: TaskItem) {
        guard let key = alertKey(item) else { return }
        announcedAlerts.insert(key)
        showDueAlert(item)
        scheduleDueAlerts() // arm the next one
    }

    private func showDueAlert(_ item: TaskItem) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { dueAlert = item }
        NotificationCenter.default.post(name: .taskDueAlert, object: nil)
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: "Task due: \(item.title)", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        alertClearTask?.cancel()
        alertClearTask = Task { @MainActor in
            try? await Task.sleep(for: Self.dueAlertDuration)
            guard !Task.isCancelled else { return }
            dismissDueAlert()
        }
    }

    /// Hides the alert (on timeout, or once the notch is opened and the task is visible).
    func dismissDueAlert() {
        alertClearTask?.cancel()
        alertClearTask = nil
        guard dueAlert != nil else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 1.0)) { dueAlert = nil }
    }

    #if DEBUG
    /// Dev aid: show the alert for a sample task without waiting for a due time.
    func debugShowDueAlert() {
        let item = TaskItem(
            id: Self.debugAlertID, title: "Prep slides for design review", isCompleted: false,
            completionDate: nil, priority: .high, listID: "mock", listName: "Reminders",
            dueDay: calendar.startOfDay(for: Date()), dueTime: Date(),
            repeatSummary: nil, location: nil)
        showDueAlert(item)
    }
    #endif
}

// MARK: - Natural-language due dates

struct ParsedDue: Equatable {
    let date: Date
    let hasTime: Bool
}

struct ParsedTaskInput: Equatable {
    /// Title with the date words removed ("Dentist next Friday 3pm" → "Dentist").
    let title: String
    let due: ParsedDue
    /// The exact text that was recognised as a date (used to let the user dismiss it).
    let matchedText: String
}

/// Finds a date in free text using Apple's built-in data detector (offline,
/// locale-aware — the same detection Mail and Notes use).
enum TaskDateParser {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    /// Words that only make sense next to a date ("Pay rent on 1 Dec" → "Pay rent").
    private static let connector = #"(?i)\s*\b(on|at|by|due|for|until)\s*$"#
    /// Signs that the user actually typed a time of day (the detector defaults to noon otherwise).
    private static let timePattern = #"(?i)(\d{1,2}(:\d{2})?\s*(am|pm|a\.m\.|p\.m\.))|(\b\d{1,2}:\d{2}\b)|\b(noon|midday|midnight|tonight|morning|afternoon|evening)\b"#

    static func parse(_ text: String, now: Date = Date()) -> ParsedTaskInput? {
        guard let detector, !text.isEmpty else { return nil }
        let ns = text as NSString
        guard let match = detector.matches(in: text, range: NSRange(location: 0, length: ns.length)).last,
              var date = match.date
        else { return nil }

        let matched = ns.substring(with: match.range)
        let trimmedMatch = matched.trimmingCharacters(in: .whitespacesAndNewlines)
        // A bare number ("Read 1984", "Buy 2") isn't a date the user meant.
        if trimmedMatch.allSatisfy({ $0.isNumber }) { return nil }

        let hasTime = matched.range(of: timePattern, options: .regularExpression) != nil
        let cal = Calendar.current

        // "3 Nov" typed on 10 Nov means next year's 3 Nov, unless a year was written.
        if !hasTime, date < cal.startOfDay(for: now),
           matched.range(of: #"\b\d{4}\b"#, options: .regularExpression) == nil,
           let nextYear = cal.date(byAdding: .year, value: 1, to: date) {
            date = nextYear
        }

        var prefix = ns.substring(to: match.range.location)
        prefix = prefix.replacingOccurrences(of: connector, with: "", options: .regularExpression)
        let suffix = ns.substring(from: match.range.location + match.range.length)
        var title = (prefix + " " + suffix)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",-–—")))
        // The detector reads meal words as times ("Lunch at noon on Friday" is all one
        // date match). Keep the meal word as the task name so it isn't lost.
        if title.isEmpty, let firstWord = trimmedMatch.split(separator: " ").first,
           ["breakfast", "brunch", "lunch", "dinner", "supper"].contains(firstWord.lowercased()) {
            title = String(firstWord)
        }
        // Only a date and no task name: treat the text as a plain title instead.
        guard !title.isEmpty else { return nil }

        return ParsedTaskInput(title: title, due: ParsedDue(date: date, hasTime: hasTime), matchedText: matched)
    }
}

// MARK: - Natural-language durations ("Work for 45 mins")

struct ParsedDuration: Equatable {
    /// Text with the duration words removed ("Work for 45 mins" → "Work").
    let remaining: String
    let minutes: Int
    /// The exact text that was recognised (used to let the user dismiss it).
    let matchedText: String
}

/// Finds how long a task should take: "for 45 min", "takes 1h 30m", "~2 hrs",
/// "(90 minutes)", "45-min", "half an hour", "an hour and a half", "1.5 hours".
/// Runs before date detection so "for 45 mins" is never read as a date.
enum TaskDurationParser {
    /// Words that introduce a duration; removed together with it.
    private static let lead = #"(?:(?:for|takes?|taking|lasting|about|around|roughly|approx(?:imately|\.)?|est(?:imated|\.)?|duration:?|~|≈)\s*)*"#
    private static let hourUnit = #"(?:h|hr|hrs|hour|hours)"#
    private static let minUnit = #"(?:m|min|mins|minute|minutes)"#

    /// Ordered most specific first; each yields minutes from its captures.
    private static let patterns: [(String, ([String]) -> Double?)] = [
        // 1h 30m · 1 hr 30 min · 1 hour and 30 minutes · 1h30
        (#"(\d+(?:[.,]\d+)?)\s*"# + hourUnit + #"\s*(?:and\s*)?(\d+)\s*"# + minUnit + #"?"#,
         { c in num(c[0]).map { $0 * 60 + (num(c[1]) ?? 0) } }),
        // an hour and a half · 1 hour and a half
        (#"(an?|one|\d+)\s*hours?\s+and\s+a\s+half"#,
         { c in (num(c[0]) ?? 1) * 60 + 30 }),
        // half an hour · half hour
        (#"half\s+(?:an?\s+)?hour"#, { _ in 30 }),
        // a quarter of an hour · quarter hour
        (#"(?:a\s+)?quarter\s+(?:of\s+)?(?:an?\s+)?hour"#, { _ in 15 }),
        // 1.5 hours · 2 hrs · 1h · an hour
        (#"(\d+(?:[.,]\d+)?|an?|one)\s*-?\s*"# + hourUnit,
         { c in num(c[0]).map { $0 * 60 } }),
        // 45 minutes · 45 min · 45-min · 45m
        (#"(\d+)\s*-?\s*"# + minUnit, { c in num(c[0]) }),
    ]

    static func parse(_ text: String) -> ParsedDuration? {
        let ns = text as NSString
        for (core, minutesFrom) in patterns {
            // Optional lead-in and brackets; the duration must stand alone as words.
            let full = #"(?i)(?<![\w.])[(\[]?\s*"# + lead + "(?:" + core + #")\s*[)\]]?(?![\w])"#
            guard let regex = try? NSRegularExpression(pattern: full),
                  let match = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).last
            else { continue }

            let captures = (1..<match.numberOfRanges).map { i -> String in
                let r = match.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            guard let raw = minutesFrom(captures) else { continue }
            let minutes = Int(raw.rounded())
            guard (1...600).contains(minutes) else { continue }

            let matched = ns.substring(with: match.range)
            // A bare "5m" / "2h" right after a number-ish word is often a measurement
            // ("2m cable"); only accept those with a lead-in or as the last word.
            if matched.range(of: #"(?i)^\s*\d+(?:[.,]\d+)?[mh]\s*$"#, options: .regularExpression) != nil,
               match.range.location + match.range.length < ns.length {
                let after = ns.substring(from: match.range.location + match.range.length)
                if after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { continue }
            }

            let remaining = (ns.substring(to: match.range.location) + " " + ns.substring(from: match.range.location + match.range.length))
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",-–—:")))
            // Only a duration and no task name: not a duration, just a title.
            guard !remaining.isEmpty else { return nil }
            return ParsedDuration(remaining: remaining, minutes: minutes, matchedText: matched)
        }
        return nil
    }

    private static func num(_ s: String) -> Double? {
        let t = s.lowercased().trimmingCharacters(in: .whitespaces)
        switch t {
        case "a", "an", "one": return 1
        case "": return nil
        default: return Double(t.replacingOccurrences(of: ",", with: "."))
        }
    }

    /// "45 min", "1 h", "1 h 30 min".
    static func label(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}

// MARK: - Natural-language priority ("Pay rent !!!", "Fix bug urgent", "p2")

struct ParsedPriority: Equatable {
    /// Text with the priority words removed.
    let remaining: String
    let priority: TaskPriority
    let matchedText: String
}

/// Finds a priority in the text. Saved to Reminders' own priority, so it syncs.
/// - `!!!` / `!!` / `!` as separate words → High / Medium / Low ("Call mom!" is left alone)
/// - "high/medium/low priority", "priority high", "priority: low" anywhere
/// - "urgent", "asap", "important", "p1/p2/p3" only as the first or last word
///   ("Read important email" is left alone)
enum TaskPriorityParser {
    private static let rules: [(String, (String) -> TaskPriority?)] = [
        (#"(?i)(?<![\w])(high|medium|med|low)\s+priority(?![\w])"#, level),
        (#"(?i)(?<![\w])priority\s*:?\s*(high|medium|med|low)(?![\w])"#, level),
        (#"(?<!\S)(!{1,3})(?!\S)"#, { $0.count == 3 ? .high : ($0.count == 2 ? .medium : .low) }),
        (#"(?i)^\s*(urgent|asap|important|p[1-3])(?![\w])[\s:,\-–—]*"#, keyword),
        (#"(?i)[\s,\-–—]*(?<![\w])(urgent|asap|important|p[1-3])[!.]*\s*$"#, keyword),
    ]

    static func parse(_ text: String) -> ParsedPriority? {
        let ns = text as NSString
        for (pattern, priorityFrom) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).last,
                  match.numberOfRanges > 1
            else { continue }
            guard let priority = priorityFrom(ns.substring(with: match.range(at: 1))) else { continue }
            let remaining = (ns.substring(to: match.range.location) + " " + ns.substring(from: match.range.location + match.range.length))
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",-–—:")))
            guard !remaining.isEmpty else { return nil }
            return ParsedPriority(remaining: capitalizeIfLeading(remaining, removedAtStart: match.range.location == 0),
                                  priority: priority, matchedText: ns.substring(with: match.range))
        }
        return nil
    }

    private static func level(_ word: String) -> TaskPriority? {
        switch word.lowercased() {
        case "high": return .high
        case "medium", "med": return .medium
        case "low": return .low
        default: return nil
        }
    }

    private static func keyword(_ word: String) -> TaskPriority? {
        switch word.lowercased() {
        case "urgent", "asap", "important", "p1": return .high
        case "p2": return .medium
        case "p3": return .low
        default: return nil
        }
    }
}

// MARK: - List tag ("Plan launch #Work")

struct ParsedListTag: Equatable {
    let remaining: String
    let listID: String
    let listName: String
    let matchedText: String
}

/// `#Work` puts the task in the Reminders list called "Work". Only matches lists
/// that exist (case and spaces ignored: `#SideProject` → "Side project").
enum TaskListTagParser {
    static func parse(_ text: String, lists: [TaskList]) -> ParsedListTag? {
        guard !lists.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"(?<![\w#])#([\p{L}\p{N}_\-]+)"#)
        else { return nil }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let tag = normalize(ns.substring(with: match.range(at: 1)))
            guard let list = lists.first(where: { normalize($0.title) == tag }) else { continue }
            let remaining = (ns.substring(to: match.range.location) + " " + ns.substring(from: match.range.location + match.range.length))
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",-–—:")))
            guard !remaining.isEmpty else { return nil }
            return ParsedListTag(remaining: capitalizeIfLeading(remaining, removedAtStart: match.range.location == 0),
                                 listID: list.id, listName: list.title,
                                 matchedText: ns.substring(with: match.range))
        }
        return nil
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
    }
}

/// "Urgent: fix login" → "Fix login": capitalise when the removed words were at the start.
private func capitalizeIfLeading(_ text: String, removedAtStart: Bool) -> String {
    guard removedAtStart, let first = text.first, first.isLowercase else { return text }
    return first.uppercased() + text.dropFirst()
}

#if DEBUG
extension TasksManager {
    /// Screenshot fixtures. In-memory only: never touches Reminders or saved defaults.
    func applyMock() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func at(_ h: Int, _ m: Int = 0) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: today)! }
        func item(_ id: String, _ title: String, done: Bool = false, due: Date? = nil,
                  time: Date? = nil, priority: TaskPriority = .none) -> TaskItem {
            TaskItem(id: id, title: title, isCompleted: done, completionDate: done ? at(9) : nil,
                     priority: priority, listID: "mock", listName: "Reminders",
                     dueDay: due, dueTime: time, repeatSummary: nil, location: nil)
        }
        authorizationStatus = .fullAccess
        selectedDate = today
        lists = [TaskList(id: "mock", title: "Reminders")]
        defaultListID = "mock"
        todo = [
            item("m1", "Prep slides for design review", due: today, time: at(15), priority: .high),
            item("m2", "Reply to client emails", due: today, time: at(11, 30)),
            item("m3", "Review pull requests", due: today),
            item("m4", "Book flights for the conference", due: today, time: at(17)),
            item("m5", "Water the plants", due: today),
        ]
        completed = [
            item("m6", "Morning workout", done: true, due: today),
            item("m7", "Plan the week", done: true, due: today),
        ]
        plannedMinutes = ["m1": 45, "m3": 25, "m2": 15]
        daysWithTasks = [today, cal.date(byAdding: .day, value: 2, to: today)!]
    }
}
#endif

// MARK: - Debug screenshot fixtures (see DebugMock)
#if DEBUG

@MainActor
enum DebugMock {
    /// While true, managers skip reloading from Reminders/Calendar and skip saving notes.
    static var active = false

    static func apply() {
        active = true
        TasksManager.shared.applyMock()
        CalendarManager.shared.applyMock()
        NotesManager.shared.applyMock()
        InsightsManager.shared.applyMock()
    }
}

extension CalendarManager {
    /// Screenshot fixtures. In-memory only; never reads or writes the real calendar.
    func applyMock() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        // Relative to now so the events always look upcoming, whatever the time.
        let base = cal.date(bySetting: .minute, value: 0, of: Date().addingTimeInterval(3600))!
        func at(_ hours: Double) -> Date { base.addingTimeInterval(hours * 3600) }
        let work = CalendarModel(
            id: "mock", account: "iCloud", title: "Work",
            color: .systemPurple, isSubscribed: false, isReminder: false)
        func event(_ id: String, _ title: String, _ start: Date, _ end: Date, _ place: String? = nil) -> EventModel {
            EventModel(
                id: id, start: start, end: end, title: title, location: place, notes: nil, url: nil,
                isAllDay: false, type: .event(.accepted), calendar: work, participants: [],
                timeZone: nil, hasRecurrenceRules: false, priority: nil)
        }
        events = [
            event("e1", "Team standup", at(0), at(0.5)),
            event("e2", "Design review", at(1.5), at(2.5), "Studio B"),
            event("e3", "Dinner with Maya", at(4), at(5.5)),
        ]
        busyDays = [
            today,
            cal.date(byAdding: .day, value: 1, to: today)!,
            cal.date(byAdding: .day, value: 3, to: today)!,
        ]
    }
}

extension NotesManager {
    /// Screenshot fixture. In-memory only; saving is disabled while mocking.
    func applyMock() {
        selectedDate = Calendar.current.startOfDay(for: Date())
        text = "Ideas for the week:\n- Simplify the onboarding flow\n- Try a 45 min focus block before lunch\n- Send the launch notes to Sam"
    }
}
#endif
