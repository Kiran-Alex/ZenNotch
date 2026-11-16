//
//  MCPTaskService.swift
//  ZenNotch
//
//  The task operations behind the MCP tools (create, update, search, complete,
//  delete). Everything goes through Apple Reminders (EventKit), the same store the
//  notch's Tasks card uses, so changes show up in the notch and on other devices.
//
//  EventKit has no subtasks or tags, so both are written into the reminder's notes:
//  subtasks as a "- [ ]" checklist, tags as "#tag" words.
//

import AppKit
import Defaults
import EventKit

struct MCPToolError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Value snapshot of a reminder (safe to move between threads).
struct MCPTaskRow: Sendable {
    let id: String
    let title: String
    let notes: String
    let completed: Bool
    let completionDate: Date?
    let due: Date?
    let hasTime: Bool
    let priority: TaskPriority
    let listID: String
    let listName: String
}

// MARK: - Conversions

enum MCPFormat {
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func string(from date: Date, hasTime: Bool) -> String {
        if !hasTime { return dayFormatter.string(from: date) }
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// ISO 8601 ("2026-11-17", "2026-11-17T16:00", with or without an offset) or plain
    /// English ("tomorrow 4pm", "next friday"). Times without an offset are local.
    static func parseDue(_ text: String) throws -> ParsedDue {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            iso.formatOptions = options
            if let d = iso.date(from: t) { return ParsedDue(date: d, hasTime: true) }
        }
        let formats: [(String, Bool)] = [
            ("yyyy-MM-dd'T'HH:mm:ss", true), ("yyyy-MM-dd'T'HH:mm", true),
            ("yyyy-MM-dd HH:mm", true), ("yyyy-MM-dd", false),
        ]
        for (format, hasTime) in formats {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = format
            f.isLenient = false
            if let d = f.date(from: t) { return ParsedDue(date: d, hasTime: hasTime) }
        }
        // The parser looks for a date inside a sentence; a leading word keeps it happy.
        if let parsed = TaskDateParser.parse("task " + t) ?? TaskDateParser.parse(t) { return parsed.due }
        throw MCPToolError("Couldn't read the date \"\(text)\". Use ISO 8601 like 2026-11-17 or 2026-11-17T16:00, or plain English like \"tomorrow 4pm\".")
    }

    static func parsePriority(_ text: String) throws -> TaskPriority {
        switch text.lowercased().trimmingCharacters(in: .whitespaces) {
        case "none", "no", "": return .none
        case "low", "p3": return .low
        case "medium", "med", "normal", "p2": return .medium
        case "high", "urgent", "important", "p1": return .high
        default: throw MCPToolError("Priority must be one of: none, low, medium, high.")
        }
    }
}

// MARK: - Notes: subtasks and tags

enum MCPNotes {
    private static let tagRegex = try! NSRegularExpression(pattern: #"(?<![\w#])#([\p{L}\p{N}_-]+)"#)

    static func tags(in text: String) -> [String] {
        let ns = text as NSString
        var seen = Set<String>(), result: [String] = []
        for m in tagRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range(at: 1))
            if seen.insert(tag.lowercased()).inserted { result.append(tag) }
        }
        return result
    }

    static func subtasks(in notes: String) -> [(title: String, done: Bool)] {
        notes.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("- [ ] ") { return (String(l.dropFirst(6)), false) }
            if l.lowercased().hasPrefix("- [x] ") { return (String(l.dropFirst(6)), true) }
            return nil
        }
    }

    /// Lines that are only hashtags (the tag line this file writes).
    private static func isTagLine(_ line: Substring) -> Bool {
        let words = line.split(separator: " ")
        return !words.isEmpty && words.allSatisfy { $0.hasPrefix("#") && $0.count > 1 }
    }

    static func cleanTag(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespacesAndNewlines))
            .replacingOccurrences(of: " ", with: "-")
    }

    /// Replaces the tag line (the last line made only of hashtags) with `tags`.
    static func setTags(_ tags: [String], in notes: String) -> String {
        var lines = notes.split(separator: "\n", omittingEmptySubsequences: false)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty || isTagLine(last) {
            lines.removeLast()
        }
        var body = lines.joined(separator: "\n")
        let cleaned = tags.map(cleanTag).filter { !$0.isEmpty }
        if !cleaned.isEmpty {
            body += (body.isEmpty ? "" : "\n\n") + cleaned.map { "#\($0)" }.joined(separator: " ")
        }
        return body
    }

    /// Adds checklist lines before the tag line, if there is one.
    static func addSubtasks(_ items: [String], to notes: String) -> String {
        let existingTags = tags(in: notes.split(separator: "\n").last(where: { isTagLine($0) }).map(String.init) ?? "")
        var body = notes
        if !existingTags.isEmpty { body = setTags([], in: notes) }
        let list = items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.map { "- [ ] \($0)" }.joined(separator: "\n")
        if !list.isEmpty { body += (body.isEmpty ? "" : "\n") + list }
        return existingTags.isEmpty ? body : setTags(existingTags, in: body)
    }
}

// MARK: - Argument helpers

enum MCPArg {
    static func string(_ v: Any?) -> String? { (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
    static func int(_ v: Any?) -> Int? {
        if let n = v as? Int { return n }
        if let d = v as? Double, d == d.rounded() { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }
    static func bool(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        if let s = v as? String { return ["true", "yes"].contains(s.lowercased()) ? true : (["false", "no"].contains(s.lowercased()) ? false : nil) }
        return nil
    }
    static func strings(_ v: Any?) -> [String]? {
        if let a = v as? [String] { return a }
        if let a = v as? [Any] { return a.compactMap { $0 as? String } }
        if let s = v as? String { return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        return nil
    }
    static func isNull(_ v: Any?) -> Bool { v is NSNull }
    /// One id or a list of ids.
    static func ids(_ args: [String: Any]) -> [String] {
        var ids = strings(args["ids"]) ?? []
        if let one = string(args["id"]), !one.isEmpty { ids.append(one) }
        var seen = Set<String>()
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

// MARK: - Task operations

extension TasksManager {
    nonisolated static func mcpRow(_ r: EKReminder) -> MCPTaskRow {
        let cal = Calendar.current
        var due: Date?
        var hasTime = false
        if let comps = r.dueDateComponents, let d = cal.date(from: comps) {
            due = d
            hasTime = comps.hour != nil
        }
        return MCPTaskRow(
            id: r.calendarItemIdentifier, title: r.title ?? "", notes: r.notes ?? "",
            completed: r.isCompleted, completionDate: r.completionDate, due: due, hasTime: hasTime,
            priority: TaskPriority(ekPriority: r.priority),
            listID: r.calendar?.calendarIdentifier ?? "", listName: r.calendar?.title ?? "")
    }

    func mcpJSON(_ row: MCPTaskRow) -> [String: Any] {
        var d: [String: Any] = [
            "id": row.id, "title": row.title, "status": row.completed ? "completed" : "open",
            "priority": row.priority.label.lowercased(), "list": row.listName,
        ]
        if let due = row.due {
            d["due"] = MCPFormat.string(from: due, hasTime: row.hasTime)
            d["has_time"] = row.hasTime
        }
        if let done = row.completionDate { d["completed_at"] = MCPFormat.string(from: done, hasTime: true) }
        if !row.notes.isEmpty { d["notes"] = row.notes }
        let tags = MCPNotes.tags(in: row.notes)
        if !tags.isEmpty { d["tags"] = tags }
        let subs = MCPNotes.subtasks(in: row.notes)
        if !subs.isEmpty { d["subtasks"] = subs.map { ["title": $0.title, "done": $0.done] as [String: Any] } }
        if let minutes = plannedMinutes[row.id] { d["duration_minutes"] = minutes }
        return d
    }

    private func mcpRequireAccess() throws {
        guard hasAccess else {
            throw MCPToolError("ZenNotch doesn't have access to Reminders. Allow it in System Settings > Privacy & Security > Reminders.")
        }
    }

    private func mcpReminder(_ id: String) throws -> EKReminder {
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw MCPToolError("No task with id \"\(id)\".")
        }
        return r
    }

    private func mcpList(_ nameOrID: String) throws -> EKCalendar {
        let all = store.calendars(for: .reminder).filter { $0.allowsContentModifications }
        if let byID = all.first(where: { $0.calendarIdentifier == nameOrID }) { return byID }
        if let byName = all.first(where: { $0.title.caseInsensitiveCompare(nameOrID) == .orderedSame }) { return byName }
        throw MCPToolError("No list named \"\(nameOrID)\". Lists: " + all.map(\.title).joined(separator: ", "))
    }

    private func mcpSave(_ reminder: EKReminder) throws {
        do { try store.save(reminder, commit: true) }
        catch { throw MCPToolError("Reminders couldn't save the change: \(error.localizedDescription)") }
        reload()
    }

    private func mcpApplyDue(_ due: ParsedDue?, to reminder: EKReminder) {
        guard let due else {
            reminder.dueDateComponents = nil
            reminder.alarms?.forEach { reminder.removeAlarm($0) }
            return
        }
        let units: Set<Calendar.Component> = due.hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
        applyDue(calendar.dateComponents(units, from: due.date), to: reminder)
    }

    // MARK: Lists

    func mcpListLists() throws -> [String: Any] {
        try mcpRequireAccess()
        let defaultID = store.defaultCalendarForNewReminders()?.calendarIdentifier
        let lists = store.calendars(for: .reminder).map { c -> [String: Any] in
            ["id": c.calendarIdentifier, "name": c.title, "default": c.calendarIdentifier == defaultID,
             "editable": c.allowsContentModifications]
        }
        return ["lists": lists]
    }

    // MARK: Create

    func mcpCreate(_ a: [String: Any]) throws -> [String: Any] {
        try mcpRequireAccess()
        guard let title = MCPArg.string(a["title"]), !title.isEmpty else { throw MCPToolError("title is required.") }
        let list: EKCalendar
        if let name = MCPArg.string(a["list"]), !name.isEmpty {
            list = try mcpList(name)
        } else if let d = store.defaultCalendarForNewReminders() ?? store.calendars(for: .reminder).first {
            list = d
        } else {
            throw MCPToolError("There's no Reminders list to add the task to.")
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = list

        var notes = MCPArg.string(a["notes"]) ?? ""
        if let subs = MCPArg.strings(a["subtasks"]), !subs.isEmpty { notes = MCPNotes.addSubtasks(subs, to: notes) }
        if let tags = MCPArg.strings(a["tags"]), !tags.isEmpty { notes = MCPNotes.setTags(tags, in: notes) }
        if !notes.isEmpty { reminder.notes = notes }

        if let p = MCPArg.string(a["priority"]) { reminder.priority = try MCPFormat.parsePriority(p).ekPriority }
        if let dueText = MCPArg.string(a["due"]), !dueText.isEmpty {
            mcpApplyDue(try MCPFormat.parseDue(dueText), to: reminder)
        }
        try mcpSave(reminder)
        if let minutes = MCPArg.int(a["duration_minutes"]), minutes > 0 {
            setPlannedMinutes(reminder.calendarItemIdentifier, minutes)
        }
        return mcpJSON(Self.mcpRow(reminder))
    }

    // MARK: Update

    private static let updatableKeys: Set<String> = [
        "id", "title", "notes", "due", "shift_days", "priority", "list", "completed",
        "tags", "add_subtasks", "duration_minutes",
    ]

    func mcpUpdate(_ a: [String: Any]) throws -> [String: Any] {
        try mcpRequireAccess()
        guard let id = MCPArg.string(a["id"]), !id.isEmpty else { throw MCPToolError("id is required.") }
        let unknown = Set(a.keys).subtracting(Self.updatableKeys)
        if !unknown.isEmpty {
            throw MCPToolError("Unknown field(s): \(unknown.sorted().joined(separator: ", ")). Allowed: \(Self.updatableKeys.subtracting(["id"]).sorted().joined(separator: ", ")).")
        }
        let reminder = try mcpReminder(id)

        if let title = MCPArg.string(a["title"]) {
            guard !title.isEmpty else { throw MCPToolError("title can't be empty.") }
            reminder.title = title
        }
        if a["notes"] != nil { reminder.notes = MCPArg.isNull(a["notes"]) ? nil : (a["notes"] as? String) }
        if let subs = MCPArg.strings(a["add_subtasks"]), !subs.isEmpty {
            reminder.notes = MCPNotes.addSubtasks(subs, to: reminder.notes ?? "")
        }
        if a["tags"] != nil {
            let tags = MCPArg.isNull(a["tags"]) ? [] : (MCPArg.strings(a["tags"]) ?? [])
            reminder.notes = MCPNotes.setTags(tags, in: reminder.notes ?? "")
        }
        if let p = MCPArg.string(a["priority"]) { reminder.priority = try MCPFormat.parsePriority(p).ekPriority }
        if let name = MCPArg.string(a["list"]), !name.isEmpty { reminder.calendar = try mcpList(name) }

        if a["due"] != nil {
            if MCPArg.isNull(a["due"]) || MCPArg.string(a["due"]) == "" {
                mcpApplyDue(nil, to: reminder)
            } else if let text = MCPArg.string(a["due"]) {
                mcpApplyDue(try MCPFormat.parseDue(text), to: reminder)
            }
        }
        if let shift = MCPArg.int(a["shift_days"]), shift != 0 {
            let row = Self.mcpRow(reminder)
            guard let due = row.due, let moved = calendar.date(byAdding: .day, value: shift, to: due) else {
                throw MCPToolError("shift_days needs a task that already has a due date.")
            }
            mcpApplyDue(ParsedDue(date: moved, hasTime: row.hasTime), to: reminder)
        }
        if let done = MCPArg.bool(a["completed"]) { reminder.isCompleted = done }
        try mcpSave(reminder)

        if a["duration_minutes"] != nil {
            setPlannedMinutes(id, MCPArg.isNull(a["duration_minutes"]) ? nil : MCPArg.int(a["duration_minutes"]))
        }
        return mcpJSON(Self.mcpRow(reminder))
    }

    /// Applies each patch on its own; one bad patch doesn't stop the rest.
    func mcpBatchUpdate(_ a: [String: Any]) throws -> [String: Any] {
        guard let updates = a["updates"] as? [[String: Any]], !updates.isEmpty else {
            throw MCPToolError("updates must be a non-empty array of {id, ...fields}.")
        }
        guard updates.count <= 100 else { throw MCPToolError("At most 100 updates per call.") }
        var results: [[String: Any]] = []
        for patch in updates {
            let id = MCPArg.string(patch["id"]) ?? ""
            do {
                results.append(["id": id, "ok": true, "task": try mcpUpdate(patch)])
            } catch let e as MCPToolError {
                results.append(["id": id, "ok": false, "error": e.message])
            }
        }
        let failed = results.filter { ($0["ok"] as? Bool) == false }.count
        return ["updated": results.count - failed, "failed": failed, "results": results]
    }

    // MARK: Complete / delete

    func mcpComplete(_ a: [String: Any]) throws -> [String: Any] {
        try mcpRequireAccess()
        let ids = MCPArg.ids(a)
        guard !ids.isEmpty else { throw MCPToolError("Give id or ids.") }
        let done = MCPArg.bool(a["completed"]) ?? true
        var results: [[String: Any]] = []
        for id in ids {
            do {
                let r = try mcpReminder(id)
                r.isCompleted = done
                try mcpSave(r)
                results.append(["id": id, "ok": true, "status": done ? "completed" : "open"])
            } catch let e as MCPToolError {
                results.append(["id": id, "ok": false, "error": e.message])
            }
        }
        return ["results": results]
    }

    func mcpDelete(_ a: [String: Any]) throws -> [String: Any] {
        try mcpRequireAccess()
        guard Defaults[.mcpAllowDelete] else {
            throw MCPToolError("Deleting is turned off. The user can allow it in ZenNotch > Settings > General > AI apps (MCP). Use complete_task instead if the task is just done.")
        }
        let ids = MCPArg.ids(a)
        guard !ids.isEmpty else { throw MCPToolError("Give id or ids.") }
        guard ids.count <= 100 else { throw MCPToolError("At most 100 tasks per call.") }
        var results: [[String: Any]] = []
        for id in ids {
            do {
                let r = try mcpReminder(id)
                let title = r.title ?? ""
                do { try store.remove(r, commit: true) }
                catch { throw MCPToolError("Reminders couldn't delete it: \(error.localizedDescription)") }
                results.append(["id": id, "ok": true, "deleted": title])
            } catch let e as MCPToolError {
                results.append(["id": id, "ok": false, "error": e.message])
            }
        }
        reload()
        return ["results": results]
    }

    // MARK: Search

    private func mcpFetch(_ predicate: NSPredicate) async -> [MCPTaskRow] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map { Self.mcpRow($0) })
            }
        }
    }

    /// Open tasks (all of them) and/or tasks completed in the last year.
    func mcpFetchRows(status: String) async -> [MCPTaskRow] {
        let calendars = visibleCalendars()
        var rows: [MCPTaskRow] = []
        if status != "completed" {
            rows += await mcpFetch(store.predicateForIncompleteReminders(
                withDueDateStarting: nil, ending: nil, calendars: calendars))
        }
        if status != "open" {
            let since = calendar.date(byAdding: .year, value: -1, to: Date())
            rows += await mcpFetch(store.predicateForCompletedReminders(
                withCompletionDateStarting: since, ending: nil, calendars: calendars))
        }
        return rows
    }

    private static func mcpSort(_ rows: [MCPTaskRow]) -> [MCPTaskRow] {
        rows.sorted { a, b in
            switch (a.due, b.due) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default:
                if a.priority != b.priority { return a.priority.rawValue > b.priority.rawValue }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }
    }

    func mcpSearch(_ a: [String: Any]) async throws -> [String: Any] {
        try mcpRequireAccess()
        let status = (MCPArg.string(a["status"]) ?? "open").lowercased()
        guard ["open", "completed", "all"].contains(status) else {
            throw MCPToolError("status must be open, completed or all.")
        }
        var rows = await mcpFetchRows(status: status)

        let cal = calendar
        let startOfToday = cal.startOfDay(for: Date())
        if let from = MCPArg.string(a["due_from"]), !from.isEmpty {
            let day = cal.startOfDay(for: try MCPFormat.parseDue(from).date)
            rows = rows.filter { ($0.due.map { cal.startOfDay(for: $0) } ?? .distantPast) >= day && $0.due != nil }
        }
        if let to = MCPArg.string(a["due_to"]), !to.isEmpty {
            let day = cal.startOfDay(for: try MCPFormat.parseDue(to).date)
            rows = rows.filter { $0.due.map { cal.startOfDay(for: $0) <= day } ?? false }
        }
        if MCPArg.bool(a["overdue"]) == true {
            let now = Date()
            rows = rows.filter { r in
                guard !r.completed, let due = r.due else { return false }
                return r.hasTime ? due < now : cal.startOfDay(for: due) < startOfToday
            }
        }
        if MCPArg.bool(a["no_due_date"]) == true { rows = rows.filter { $0.due == nil } }
        if let p = MCPArg.string(a["min_priority"]), !p.isEmpty {
            let level = try MCPFormat.parsePriority(p).rawValue
            rows = rows.filter { $0.priority.rawValue >= level }
        }
        if let list = MCPArg.string(a["list"]), !list.isEmpty {
            rows = rows.filter { $0.listName.caseInsensitiveCompare(list) == .orderedSame || $0.listID == list }
        }
        if let tag = MCPArg.string(a["tag"]), !tag.isEmpty {
            let wanted = MCPNotes.cleanTag(tag).lowercased()
            rows = rows.filter { r in
                (MCPNotes.tags(in: r.notes) + MCPNotes.tags(in: r.title)).contains { $0.lowercased() == wanted }
            }
        }
        if let q = MCPArg.string(a["query"]), !q.isEmpty {
            rows = rows.filter { r in
                [r.title, r.notes, r.listName].contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
        }

        rows = Self.mcpSort(rows)
        let limit = min(max(MCPArg.int(a["limit"]) ?? 50, 1), 200)
        return [
            "total_matches": rows.count, "returned": min(rows.count, limit),
            "tasks": rows.prefix(limit).map { mcpJSON($0) },
        ]
    }

    // MARK: Resources (markdown)

    /// "today" = overdue + due today, "overdue", or "active" = every open task grouped by when.
    func mcpMarkdown(scope: String) async throws -> String {
        try mcpRequireAccess()
        let rows = Self.mcpSort(await mcpFetchRows(status: "open"))
        let cal = calendar
        let today = cal.startOfDay(for: Date())
        let now = Date()

        func isOverdue(_ r: MCPTaskRow) -> Bool {
            guard let due = r.due else { return false }
            return r.hasTime ? due < now && cal.startOfDay(for: due) <= today : cal.startOfDay(for: due) < today
        }
        func isToday(_ r: MCPTaskRow) -> Bool { r.due.map { cal.isDateInToday($0) } ?? false && !isOverdue(r) }

        let overdue = rows.filter(isOverdue)
        let dueToday = rows.filter(isToday)
        let upcoming = rows.filter { r in r.due != nil && !isOverdue(r) && !isToday(r) }
        let undated = rows.filter { $0.due == nil }

        func line(_ r: MCPTaskRow) -> String {
            var parts = ["- [ ] \(r.title)"]
            if let due = r.due {
                parts.append(r.hasTime
                    ? due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                    : due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
            }
            if r.priority != .none { parts.append("\(r.priority.label) priority") }
            if !r.listName.isEmpty { parts.append(r.listName) }
            let tags = MCPNotes.tags(in: r.notes)
            if !tags.isEmpty { parts.append(tags.map { "#\($0)" }.joined(separator: " ")) }
            return parts.joined(separator: " · ") + " (id: \(r.id))"
        }
        func section(_ name: String, _ items: [MCPTaskRow]) -> String {
            items.isEmpty ? "" : "\n## \(name) (\(items.count))\n" + items.map(line).joined(separator: "\n") + "\n"
        }

        let stamp = Date().formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute())
        switch scope {
        case "overdue":
            return "# Overdue tasks, as of \(stamp)\n" + (overdue.isEmpty ? "\nNothing is overdue.\n" : section("Overdue", overdue))
        case "today":
            let body = section("Overdue", overdue) + section("Due today", dueToday)
            return "# Today, \(stamp)\n" + (body.isEmpty ? "\nNothing due today and nothing overdue.\n" : body)
        default:
            let body = section("Overdue", overdue) + section("Due today", dueToday)
                + section("Upcoming", upcoming) + section("No due date", undated)
            return "# All open tasks, as of \(stamp)\n" + (body.isEmpty ? "\nNo open tasks.\n" : body)
        }
    }
}
