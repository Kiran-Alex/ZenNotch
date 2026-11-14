//
//  FocusTimerManager.swift
//  ZenNotch
//
//  Focus sessions linked to a task. The countdown is based on an end date (not
//  a ticking counter), so it stays correct while the notch is closed. Focused
//  time is totalled per reminder locally; Reminders has nowhere to store it.
//

import AppKit
import Defaults
import SwiftUI
import UserNotifications

@MainActor
final class FocusTimerManager: ObservableObject {
    static let shared = FocusTimerManager()

    enum Phase { case idle, running, paused, finished }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var taskID: String?
    @Published private(set) var taskTitle: String?
    /// Current session length in seconds (the linked task's planned length, if it has
    /// one, otherwise the default from "Set time").
    @Published private(set) var duration: TimeInterval
    @Published private(set) var endDate: Date?
    @Published private(set) var pausedRemaining: TimeInterval?
    @Published private(set) var totals: [String: Int]

    /// Start of the current running stretch (for adding up focused time).
    private var segmentStart: Date?
    private var finishTimer: Timer?

    private init() {
        duration = TimeInterval(Defaults[.focusDuration] * 60)
        totals = Defaults[.focusTotals]
    }

    var isActive: Bool { phase == .running || phase == .paused }

    func remaining(at now: Date = Date()) -> TimeInterval {
        switch phase {
        case .running: return max(0, (endDate ?? now).timeIntervalSince(now))
        case .paused: return pausedRemaining ?? duration
        case .finished: return 0
        case .idle: return duration
        }
    }

    func progress(at now: Date = Date()) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, 1 - remaining(at: now) / duration))
    }

    /// Focused minutes for a task (shown as "Focused · 45 min" on the task row).
    func focusedMinutes(for id: String) -> Int {
        var seconds = totals[id] ?? 0
        if phase == .running, taskID == id, let start = segmentStart {
            seconds += Int(Date().timeIntervalSince(start))
        }
        return seconds / 60
    }

    // MARK: Linking

    func link(_ task: TaskItem?) {
        guard taskID != task?.id else { return }
        if phase == .running { recordSegment() }
        taskID = task?.id
        taskTitle = task?.title
        if phase == .running { segmentStart = Date() }
        applyPlannedDurationIfIdle()
    }

    private var defaultDuration: TimeInterval { TimeInterval(Defaults[.focusDuration] * 60) }

    /// Planned length of the linked task, when it has one ("Work for 45 mins").
    var plannedDurationForLinkedTask: TimeInterval? {
        guard let id = taskID, let minutes = TasksManager.shared.plannedMinutes[id] else { return nil }
        return TimeInterval(minutes * 60)
    }

    /// Before a session starts, the timer shows the linked task's planned length.
    private func applyPlannedDurationIfIdle() {
        guard phase == .idle || phase == .finished else { return }
        duration = plannedDurationForLinkedTask ?? defaultDuration
        if phase == .finished { phase = .idle }
    }

    func plannedDurationChanged(for id: String) {
        if id == taskID { applyPlannedDurationIfIdle() }
    }

    /// Keeps the linked title fresh after a rename (or unlinks a deleted task).
    func syncLinkedTask(with todo: [TaskItem]) {
        guard let id = taskID, let item = todo.first(where: { $0.id == id }) else { return }
        if item.title != taskTitle { taskTitle = item.title }
    }

    // MARK: Controls

    /// Starts (or resumes) a session, optionally on a specific task.
    func start(task: TaskItem? = nil) {
        if let task { link(task) }
        switch phase {
        case .running:
            return
        case .paused:
            resume()
            return
        case .idle, .finished:
            requestNotificationPermission()
            endDate = Date().addingTimeInterval(duration)
            pausedRemaining = nil
            phase = .running
            segmentStart = Date()
            scheduleFinish()
        }
    }

    func pause() {
        guard phase == .running else { return }
        recordSegment()
        pausedRemaining = remaining()
        endDate = nil
        phase = .paused
        finishTimer?.invalidate()
    }

    func resume() {
        guard phase == .paused else { return }
        endDate = Date().addingTimeInterval(pausedRemaining ?? duration)
        pausedRemaining = nil
        phase = .running
        segmentStart = Date()
        scheduleFinish()
    }

    func toggle(task: TaskItem? = nil) {
        if phase == .running, task == nil || task?.id == taskID { pause() } else { start(task: task) }
    }

    func reset() {
        if phase == .running { recordSegment() }
        finishTimer?.invalidate()
        endDate = nil
        pausedRemaining = nil
        phase = .idle
    }

    /// ✓: ends the session and marks the linked task done in Reminders.
    func complete() {
        let id = taskID
        reset()
        if let id, let item = TasksManager.shared.todo.first(where: { $0.id == id }) {
            TasksManager.shared.setCompleted(item, true)
        }
        taskID = nil
        taskTitle = nil
        duration = defaultDuration
    }

    func setDuration(minutes: Int) {
        let clamped = min(max(minutes, 1), 240)
        Defaults[.focusDuration] = clamped
        duration = TimeInterval(clamped * 60)
        // A new length applies immediately unless a session is underway.
        if phase == .finished { phase = .idle }
    }

    // MARK: Internals

    private func scheduleFinish() {
        finishTimer?.invalidate()
        let interval = remaining()
        finishTimer = Timer.scheduledTimer(withTimeInterval: max(0.1, interval), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finish() }
        }
    }

    private func finish() {
        guard phase == .running else { return }
        // Timers can fire a little early/late (e.g. after sleep): re-check the clock.
        if remaining() > 0.5 {
            scheduleFinish()
            return
        }
        recordSegment()
        endDate = nil
        phase = .finished
        AlertSound.focusDone.play()
        postFinishedNotification()
    }

    private func recordSegment() {
        guard let start = segmentStart else { return }
        segmentStart = nil
        let now = Date()
        let seconds = Int(now.timeIntervalSince(start))
        guard seconds > 0 else { return }
        logDaily(from: start, to: now)
        guard let id = taskID else { return }
        totals[id, default: 0] += seconds
        Defaults[.focusTotals] = totals
    }

    /// Adds focused time to the per-day log (split at midnight), with or without a task.
    private func logDaily(from start: Date, to end: Date) {
        let cal = Calendar.current
        var daily = Defaults[.focusDaily]
        var cursor = start
        while cursor < end {
            let nextDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: cursor))!
            let sliceEnd = min(end, nextDay)
            daily[focusDayKey(cursor), default: 0] += Int(sliceEnd.timeIntervalSince(cursor))
            cursor = sliceEnd
        }
        // Keep about two months.
        if let cutoff = cal.date(byAdding: .day, value: -60, to: Date()) {
            let oldest = focusDayKey(cutoff)
            daily = daily.filter { $0.key >= oldest }
        }
        Defaults[.focusDaily] = daily
    }

    /// Seconds of the session running right now that aren't in the log yet.
    var unloggedSecondsToday: Int {
        guard phase == .running, let start = segmentStart else { return 0 }
        let todayStart = Calendar.current.startOfDay(for: Date())
        return Int(Date().timeIntervalSince(max(start, todayStart)))
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    private func postFinishedNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Focus session done"
        content.body = taskTitle.map { "\($0) · \(Int(duration / 60)) min" } ?? "\(Int(duration / 60)) min of focus"
        // The sound is played by the app (softer than the default alert sound).
        let request = UNNotificationRequest(identifier: "zennotch.focus.done", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
