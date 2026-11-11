//
//  EventsCardView.swift
//  ZenNotch
//
//  Events card: today's calendar events, then today's timed reminders (tick to
//  complete). Updates on its own when Calendar/Reminders change.
//

import AppKit
import EventKit
import SwiftUI

struct EventsCardView: View {
    @Environment(\.notchScale) var notchScale
    /// Card size value scaled for the notch's design proportions and this screen.
    private func cs(_ value: CGFloat) -> CGFloat { value * cardUIScale * notchScale }
    @ObservedObject private var calendar = CalendarManager.shared
    /// Bottom of the list content in the scroll viewport (for the overflow fade).
    @State private var contentBottom: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: cs(6)) {
                Image(systemName: "calendar")
                    .font(.system(size: cs(CardType.titleIcon), weight: .semibold))
                Text("Events")
                    .font(.system(size: cs(CardType.title), weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: cs(4))
                moreMenu
            }
            .padding(.top, cs(15))
            .padding(.bottom, cs(7))

            if calendar.calendarAuthorizationStatus != .fullAccess {
                accessPrompt
            } else if events.isEmpty && reminders.isEmpty {
                Text("Nothing scheduled today.")
                    .font(.system(size: cs(12.5)))
                    .foregroundStyle(PaperPalette.inkSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { viewport in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: cs(6)) {
                            if !events.isEmpty {
                                sectionLabel("Today")
                                ForEach(events) { eventRow($0) }
                            }
                            if !reminders.isEmpty {
                                sectionLabel("Reminders")
                                    .padding(.top, cs(events.isEmpty ? 0 : 4))
                                ForEach(reminders) { reminderRow($0) }
                            }
                        }
                        .background(
                            // Where the list's bottom edge sits relative to the visible area
                            // (updates as it scrolls; past the bottom means more is hidden).
                            GeometryReader { content in
                                let bottom = content.frame(in: .global).maxY - viewport.frame(in: .global).minY
                                Color.clear
                                    .onAppear { contentBottom = bottom }
                                    .onChange(of: bottom) { _, new in contentBottom = new }
                            }
                        )
                    }
                    // Fade the bottom edge only while more is hidden below (like the tasks list).
                    .mask {
                        let hasMore = contentBottom > viewport.size.height + 1
                        VStack(spacing: 0) {
                            Color.black
                            LinearGradient(colors: [.black, .black.opacity(hasMore ? 0 : 1)],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: cs(24))
                        }
                        .animation(.easeOut(duration: 0.2), value: hasMore)
                    }
                }
            }

            footer
                .padding(.top, cs(6))
                .padding(.bottom, cs(12))
        }
        .padding(.horizontal, cs(8))
        .task { await refresh() }
        // Changes from Calendar, Reminders, iCloud, or this app.
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        await calendar.updateCurrentDate(Date())
    }

    // MARK: Data

    private var events: [EventModel] {
        calendar.events
            .filter { !$0.type.isReminder }
            .sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
    }

    /// Timed reminders due today that are still open (all-day ones live in the tasks card).
    private var reminders: [EventModel] {
        calendar.events
            .filter { event in
                guard case .reminder(let completed) = event.type else { return false }
                return !completed && !event.isAllDay
            }
            .sorted { $0.start < $1.start }
    }

    // MARK: Rows

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: cs(CardType.label), weight: .semibold))
            .kerning(0.4)
            .foregroundStyle(PaperPalette.inkSecondary)
    }

    private func eventRow(_ event: EventModel) -> some View {
        HStack(alignment: .top, spacing: cs(4)) {
            RoundedRectangle(cornerRadius: cs(1.5))
                .fill(Color(nsColor: event.calendar.color))
                .frame(width: cs(3))
            VStack(alignment: .leading, spacing: cs(2)) {
                Text(event.title)
                    .font(.system(size: cs(CardType.body), weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(timeRange(event))
                    .font(.system(size: cs(11)))
                    .foregroundStyle(PaperPalette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, cs(7))
        .padding(.horizontal, cs(6))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.07), in: RoundedRectangle(cornerRadius: cs(8), style: .continuous))
        .opacity(event.eventStatus == .ended ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { open(event) }
        .help("Open in Calendar")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func reminderRow(_ reminder: EventModel) -> some View {
        HStack(alignment: .top, spacing: cs(4)) {
            VStack(alignment: .leading, spacing: cs(2)) {
                Text(reminder.title)
                    .font(.system(size: cs(CardType.body), weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(reminder.start.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: cs(11)))
                    .foregroundStyle(PaperPalette.inkSecondary)
            }
            Spacer(minLength: 0)
            CheckCircle(isOn: false, tint: PaperPalette.slate, size: 14.5) {
                Task { await calendar.setReminderCompleted(reminderID: reminder.id, completed: true) }
            }
            .accessibilityLabel("Mark \(reminder.title) as done")
        }
        .padding(.vertical, cs(7))
        .padding(.horizontal, cs(6))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.07), in: RoundedRectangle(cornerRadius: cs(8), style: .continuous))
    }

    private func timeRange(_ event: EventModel) -> String {
        if event.isAllDay { return "All day" }
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }

    private func open(_ event: EventModel) {
        if let url = event.calendarAppURL() { NSWorkspace.shared.open(url) }
    }

    // MARK: Footer / menu / access

    private var footer: some View {
        HStack(spacing: cs(4)) {
            Image(systemName: "clock")
            Text(footerText)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .font(.system(size: cs(11.5)))
        .foregroundStyle(PaperPalette.inkSecondary)
    }

    /// What's next today, counting both calendar events and timed reminders.
    private var footerText: String {
        let now = Date()
        if let current = events.first(where: { !$0.isAllDay && $0.eventStatus == .inProgress }) {
            return "Now · until " + current.end.formatted(date: .omitted, time: .shortened)
        }
        let upcoming = (events.filter { !$0.isAllDay } + reminders)
            .filter { $0.start > now }
            .min { $0.start < $1.start }
        if let next = upcoming {
            return "Next · " + next.start.formatted(date: .omitted, time: .shortened)
        }
        if events.isEmpty && reminders.isEmpty { return "Nothing scheduled" }
        return "Nothing left today"
    }

    private var moreMenu: some View {
        Menu {
            if !calendar.eventCalendars.isEmpty {
                Menu("Calendars") {
                    ForEach(calendar.eventCalendars, id: \.id) { cal in
                        Button {
                            Task { await calendar.setCalendarSelected(cal, isSelected: !calendar.getCalendarSelected(cal)) }
                        } label: {
                            if calendar.getCalendarSelected(cal) {
                                Label(cal.title, systemImage: "checkmark")
                            } else {
                                Text(cal.title)
                            }
                        }
                    }
                }
            }
            Button("Open Calendar") {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
                    NSWorkspace.shared.openApplication(at: url, configuration: .init())
                }
            }
            Button("Calendar Settings…") {
                DispatchQueue.main.async { SettingsWindowController.shared.showWindow() }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: cs(12.5), weight: .semibold))
                .frame(width: cs(17), height: cs(17))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Events options")
    }

    private var accessPrompt: some View {
        VStack(spacing: cs(8)) {
            Text(calendar.calendarAuthorizationStatus == .notDetermined
                 ? "Allow Calendar access to see today's events."
                 : "Calendar access is turned off.")
                .font(.system(size: cs(12.5)))
                .foregroundStyle(PaperPalette.inkSecondary)
                .multilineTextAlignment(.center)
            if calendar.calendarAuthorizationStatus == .notDetermined {
                Button("Allow Access") { Task { await calendar.checkCalendarAuthorization() } }
            } else {
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
