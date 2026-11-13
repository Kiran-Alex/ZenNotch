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

    private let store = EKEventStore()
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
