//
//  CalendarManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 08/09/24.
//

import Defaults
import EventKit
import SwiftUI

// MARK: - Meeting alerts

enum MeetingAlertKind: Equatable {
    /// A few minutes before the start.
    case soon
    /// At the start time.
    case now
}

struct MeetingAlert: Equatable {
    let event: EventModel
    let kind: MeetingAlertKind
    /// When this alert fired; replays the icon animation per alert.
    let firedAt: Date
}

// MARK: - CalendarManager

@MainActor
class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    @Published var currentWeekStartDate: Date
    @Published var events: [EventModel] = []
    @Published var allCalendars: [CalendarModel] = []
    @Published var eventCalendars: [CalendarModel] = []
    @Published var reminderLists: [CalendarModel] = []
    @Published var selectedCalendarIDs: Set<String> = []
    @Published var calendarAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var reminderAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    private var selectedCalendars: [CalendarModel] = []
    private let calendarService = CalendarService()

    private var eventStoreChangedObserver: NSObjectProtocol?

    /// The "starts in" / "starting now" card dropped down from the closed notch.
    @Published private(set) var meetingAlert: MeetingAlert?
    private var meetingTimer: Timer?
    private var meetingClearTask: Task<Void, Never>?
    private var meetingScanTask: Task<Void, Never>?
    /// Alert keys already shown this run, so each one fires once.
    private var announcedMeetings: Set<String> = []
    /// Events joined from an alert; their "starting now" card is skipped.
    private var joinedMeetings: Set<String> = []

    private init() {
        self.currentWeekStartDate = CalendarManager.startOfDay(Date())
        // Read the real status up front so Settings doesn't flash "denied" while it loads.
        self.calendarAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
        self.reminderAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
        setupEventStoreChangedObserver()
        Task {
            await reloadCalendarAndReminderLists()
        }
    }

    deinit {
        if let observer = eventStoreChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupEventStoreChangedObserver() {
        eventStoreChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task {
                await self?.reloadCalendarAndReminderLists()
            }
        }
    }

    @MainActor
    func reloadCalendarAndReminderLists() async {
        let all = await calendarService.calendars()
        self.eventCalendars = all.filter { !$0.isReminder }
        self.reminderLists = all.filter { $0.isReminder }
        self.allCalendars = all // for legacy compatibility, can be removed if not needed
        updateSelectedCalendars()
    }

    func checkCalendarAuthorization() async {
        let status = EKEventStore.authorizationStatus(for: .event)
        DispatchQueue.main.async {
            print("📅 Current calendar authorization status: \(status)")
            self.calendarAuthorizationStatus = status
        }

        switch status {
        case .notDetermined:
            guard let granted = try? await calendarService.requestAccess(to: .event) else {
                self.calendarAuthorizationStatus = .notDetermined
                return
            }
            self.calendarAuthorizationStatus = granted ? .fullAccess : .denied
            if granted {
                await reloadCalendarAndReminderLists()
                events = await calendarService.events(
                    from: currentWeekStartDate,
                    to: Calendar.current.date(byAdding: .day, value: 1, to: currentWeekStartDate)!,
                    calendars: selectedCalendars.map { $0.id })
            }
        case .restricted, .denied:
            NSLog("Calendar access denied or restricted")
        case .fullAccess:
            NSLog("Full access")
            await reloadCalendarAndReminderLists()
            events = await calendarService.events(
                from: currentWeekStartDate,
                to: Calendar.current.date(byAdding: .day, value: 1, to: currentWeekStartDate)!,
                calendars: selectedCalendars.map { $0.id })
        case .writeOnly:
            NSLog("Write only")
        @unknown default:
            print("Unknown authorization status")
        }
    }
    
    func checkReminderAuthorization() async {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        DispatchQueue.main.async {
            print("📅 Current reminder authorization status: \(status)")
            self.reminderAuthorizationStatus = status
        }

        switch status {
        case .notDetermined:
            guard let granted = try? await calendarService.requestAccess(to: .reminder) else {
                self.reminderAuthorizationStatus = .notDetermined
                return
            }
            self.reminderAuthorizationStatus = granted ? .fullAccess : .denied
            if granted {
                await reloadCalendarAndReminderLists()
            }
        case .restricted, .denied:
            NSLog("Reminder access denied or restricted")
        case .fullAccess:
            NSLog("Full access")
            await reloadCalendarAndReminderLists()
        case .writeOnly:
            NSLog("Write only")
        @unknown default:
            print("Unknown authorization status")
        }
    }
        

    func updateSelectedCalendars() {
        // Populate selectedCalendarIDs based on Defaults calendar selection state
        switch Defaults[.calendarSelectionState] {
        case .all:
            selectedCalendarIDs = Set(allCalendars.map { $0.id })
        case .selected(let identifiers):
            selectedCalendarIDs = identifiers
        }

        // Update the local calendar objects that correspond to the selected ids
        selectedCalendars = allCalendars.filter { selectedCalendarIDs.contains($0.id) }
        // Calendars loaded, changed or re-selected: re-arm meeting alerts.
        scheduleMeetingAlerts()
    }

    func getCalendarSelected(_ calendar: CalendarModel) -> Bool {
        return selectedCalendarIDs.contains(calendar.id)
    }

    func setCalendarSelected(_ calendar: CalendarModel, isSelected: Bool) async {
        var selectionState = Defaults[.calendarSelectionState]

        switch selectionState {
        case .all:
            if !isSelected {
                let identifiers = Set(allCalendars.map { $0.id }).subtracting([calendar.id])
                selectionState = .selected(identifiers)
            }

        case .selected(var identifiers):
            if isSelected {
                identifiers.insert(calendar.id)
            } else {
                identifiers.remove(calendar.id)
            }

            selectionState =
                identifiers.isEmpty
                ? .all : identifiers.count == allCalendars.count ? .all : .selected(identifiers)  // if empty, select all
        }

        Defaults[.calendarSelectionState] = selectionState
        updateSelectedCalendars()
        await updateEvents()
    }

    static func startOfDay(_ date: Date) -> Date {
        return Calendar.current.startOfDay(for: date)
    }

    func updateCurrentDate(_ date: Date) async {
        currentWeekStartDate = Calendar.current.startOfDay(for: date)
        await updateEvents()
    }

    // MARK: Meeting alerts

    private static let meetingStartDuration: Duration = .seconds(120)
    private static let meetingLeadDuration: Duration = .seconds(60)
    /// If an alert would fire later than this (e.g. the Mac was asleep), it's skipped.
    private static let meetingGrace: TimeInterval = 3 * 60
    static let previewMeetingID = "preview-meeting"

    /// Finds the next "starts in" or "starting now" moment among upcoming events and
    /// arms a timer for it. Runs on calendar changes, so edits and syncs re-arm it.
    func scheduleMeetingAlerts() {
        meetingScanTask?.cancel()
        #if DEBUG
        if DebugMock.active { return }
        #endif
        let authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        guard Defaults[.meetingAlertsEnabled], authorized else {
            meetingTimer?.invalidate()
            meetingTimer = nil
            if meetingAlert?.event.id != Self.previewMeetingID { dismissMeetingAlert() }
            return
        }
        meetingScanTask = Task { @MainActor in
            let now = Date()
            let earliest = now.addingTimeInterval(-Self.meetingGrace)
            let events = await calendarService.events(
                from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(36 * 3600),
                calendars: selectedCalendars.map { $0.id })
            guard !Task.isCancelled else { return }

            let withoutLink = Defaults[.meetingAlertsWithoutLink]
            let eligible = events.filter { event in
                guard case .event(let status) = event.type, status != .declined,
                      !event.isAllDay else { return false }
                return withoutLink || EventsCardView.meetingLink(event) != nil
            }
            // Cancelled, moved or now ineligible: take the card away.
            if let current = meetingAlert, current.event.id != Self.previewMeetingID,
               !eligible.contains(where: { $0.id == current.event.id && $0.start == current.event.start }) {
                dismissMeetingAlert()
            }

            let lead = Double(Defaults[.meetingAlertLeadMinutes]) * 60
            var candidates: [(event: EventModel, kind: MeetingAlertKind, fire: Date, key: String)] = []
            for event in eligible {
                let base = "\(event.id)@\(Int(event.start.timeIntervalSince1970))"
                let leadFire = event.start.addingTimeInterval(-lead)
                if lead > 0, leadFire >= earliest, now < event.start {
                    candidates.append((event, .soon, leadFire, base + "#soon"))
                }
                if event.start >= earliest, !joinedMeetings.contains(base) {
                    candidates.append((event, .now, event.start, base + "#now"))
                }
            }
            let pending = candidates
                .filter { !announcedMeetings.contains($0.key) }
                .sorted { $0.fire < $1.fire }

            meetingTimer?.invalidate()
            meetingTimer = nil

            // Everything already due counts as shown; only the latest is displayed.
            let ready = pending.filter { $0.fire <= now }
            if let latest = ready.last {
                ready.forEach { announcedMeetings.insert($0.key) }
                showMeetingAlert(MeetingAlert(event: latest.event, kind: latest.kind, firedAt: now))
            }
            guard let next = pending.first(where: { $0.fire > now }) else { return }
            let timer = Timer(fire: next.fire, interval: 0, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.scheduleMeetingAlerts() }
            }
            RunLoop.main.add(timer, forMode: .common)
            meetingTimer = timer
        }
    }

    private func showMeetingAlert(_ alert: MeetingAlert) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { meetingAlert = alert }
        if Defaults[.taskAlertSound] {
            NSSound(named: alert.kind == .now ? "Glass" : "Tink")?.play()
        }
        let spoken = alert.kind == .now ? "Starting now: \(alert.event.title)" : "Starting soon: \(alert.event.title)"
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: spoken, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        meetingClearTask?.cancel()
        let duration = alert.kind == .now ? Self.meetingStartDuration : Self.meetingLeadDuration
        meetingClearTask = Task { @MainActor in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            dismissMeetingAlert()
        }
    }

    /// Tucks the card away (timeout, Got it, or the notch was opened).
    func dismissMeetingAlert() {
        meetingClearTask?.cancel()
        meetingClearTask = nil
        guard meetingAlert != nil else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 1.0)) { meetingAlert = nil }
    }

    /// Opens the meeting link and skips the "starting now" card for this event.
    func joinMeetingFromAlert() {
        guard let alert = meetingAlert else { return }
        dismissMeetingAlert()
        guard alert.event.id != Self.previewMeetingID else { return }
        if let link = EventsCardView.meetingLink(alert.event) {
            NSWorkspace.shared.open(link.url)
        }
        joinedMeetings.insert("\(alert.event.id)@\(Int(alert.event.start.timeIntervalSince1970))")
        scheduleMeetingAlerts()
    }

    /// Shows a sample alert (Settings > Meeting alerts > Preview). Join opens nothing.
    func previewMeetingAlert(_ kind: MeetingAlertKind, withLink: Bool = true) {
        let lead = Double(max(1, Defaults[.meetingAlertLeadMinutes])) * 60
        let start = kind == .now ? Date() : Date().addingTimeInterval(lead)
        let cal = CalendarModel(id: "preview", account: "", title: "Work",
                                color: .systemBlue, isSubscribed: false, isReminder: false)
        let event = EventModel(
            id: Self.previewMeetingID, start: start, end: start.addingTimeInterval(1800),
            title: "Team standup", location: nil, notes: nil,
            url: withLink ? URL(string: "https://meet.google.com/abc-defg-hij") : nil,
            isAllDay: false, type: .event(.accepted), calendar: cal, participants: [],
            timeZone: nil, hasRecurrenceRules: false, priority: nil)
        showMeetingAlert(MeetingAlert(event: event, kind: kind, firedAt: Date()))
    }

    private func updateEvents() async {
        #if DEBUG
        if DebugMock.active { return }
        #endif
        let calendarIDs = selectedCalendars.map { $0.id }
        let eventsResult = await calendarService.events(
            from: currentWeekStartDate,
            to: Calendar.current.date(byAdding: .day, value: 1, to: currentWeekStartDate)!,
            calendars: calendarIDs
        )
        self.events = eventsResult
    }
    
    /// Start-of-day dates (in the window from `updateBusyDays`) that have at least one
    /// calendar event or open timed reminder. Drives the dots under the week strip.
    @Published var busyDays: Set<Date> = []

    func updateBusyDays(from start: Date, days: Int) async {
        #if DEBUG
        if DebugMock.active { return }
        #endif
        let cal = Calendar.current
        let windowStart = cal.startOfDay(for: start)
        guard let windowEnd = cal.date(byAdding: .day, value: days, to: windowStart) else { return }
        let items = await calendarService.events(
            from: windowStart, to: windowEnd, calendars: selectedCalendars.map { $0.id })
        var result = Set<Date>()
        for item in items {
            if case .reminder(let completed) = item.type, completed || item.isAllDay { continue }
            // Multi-day events mark every day they cover (end is exclusive).
            let last = item.end > item.start ? item.end.addingTimeInterval(-1) : item.start
            var day = cal.startOfDay(for: max(item.start, windowStart))
            while day < windowEnd && day <= last {
                result.insert(day)
                guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        busyDays = result
    }

    func setReminderCompleted(reminderID: String, completed: Bool) async {
        await calendarService.setReminderCompleted(reminderID: reminderID, completed: completed)
        // Refresh events after updating
        events = await calendarService.events(
            from: currentWeekStartDate,
            to: Calendar.current.date(byAdding: .day, value: 1, to: currentWeekStartDate)!,
            calendars: selectedCalendars.map { $0.id })
    }
}
