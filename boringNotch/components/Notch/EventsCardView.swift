//
//  EventsCardView.swift
//  ZenNotch
//
//  Events card: a 7-day strip (today + 6, dots on busy days) over a timeline of
//  the chosen day. Events and open timed reminders sit beside their start time;
//  on today the current or next event is raised as a dark card with a countdown
//  and a Join button when it has a meeting link. Updates on its own when
//  Calendar/Reminders change.
//

import AppKit
import EventKit
import SwiftUI

struct EventsCardView: View {
    @Environment(\.notchScale) var notchScale
    /// Card size value scaled for the notch's design proportions and this screen.
    private func cs(_ value: CGFloat) -> CGFloat { value * cardUIScale * notchScale }
    @ObservedObject private var calendar = CalendarManager.shared
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    /// Bottom of the list content in the scroll viewport (for the overflow fade).
    @State private var contentBottom: CGFloat = 0

    private static let stripDays = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            weekStrip
                .padding(.top, cs(14))
            Rectangle()
                .fill(PaperPalette.divider)
                .frame(height: 1)
                .padding(.top, cs(7))
                .padding(.bottom, cs(9))
                .padding(.horizontal, cs(2))

            if calendar.calendarAuthorizationStatus != .fullAccess {
                accessPrompt
            } else if items.isEmpty {
                Text("Nothing scheduled.")
                    .font(.system(size: cs(12.5)))
                    .foregroundStyle(PaperPalette.inkSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                timeline
            }

            footer
                .padding(.top, cs(6))
                .padding(.bottom, cs(11))
        }
        .padding(.horizontal, cs(6))
        .task { await refresh() }
        .onAppear {
            // Reopening the notch starts on today again.
            let today = Calendar.current.startOfDay(for: Date())
            if selectedDay != today {
                selectedDay = today
                Task { await refresh() }
            }
        }
        // Changes from Calendar, Reminders, iCloud, or this app.
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            selectedDay = Calendar.current.startOfDay(for: Date())
            Task { await refresh() }
        }
    }

    private func refresh() async {
        await calendar.updateCurrentDate(selectedDay)
        await calendar.updateBusyDays(from: Date(), days: Self.stripDays)
    }

    private func select(_ day: Date) {
        guard day != selectedDay else { return }
        withAnimation(.smooth(duration: 0.2)) { selectedDay = day }
        Task { await calendar.updateCurrentDate(day) }
    }

    // MARK: Data

    private var isToday: Bool { Calendar.current.isDateInToday(selectedDay) }

    private var weekDays: [Date] {
        let today = Calendar.current.startOfDay(for: Date())
        return (0..<Self.stripDays).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }
    }

    /// All-day events first, then timed events and open timed reminders by start time.
    /// (All-day reminders live in the tasks card.)
    private var items: [EventModel] {
        let shown = calendar.events.filter { item in
            if case .reminder(let completed) = item.type { return !completed && !item.isAllDay }
            return true
        }
        return shown.sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
    }

    /// Today's in-progress event, or else the next one to start.
    private func featuredID(now: Date) -> String? {
        guard isToday else { return nil }
        let timed = items.filter { !$0.isAllDay && !$0.type.isReminder }
        if let current = timed.first(where: { $0.start <= now && $0.end > now }) { return current.id }
        return timed.first(where: { $0.start > now })?.id
    }

    // MARK: Week strip

    private var weekStrip: some View {
        HStack(spacing: 0) {
            ForEach(weekDays, id: \.self) { day in
                let selected = Calendar.current.isDate(day, inSameDayAs: selectedDay)
                let busy = calendar.busyDays.contains(day)
                Button { select(day) } label: {
                    VStack(spacing: cs(3)) {
                        Text(Self.letterFormatter.string(from: day))
                            .font(.system(size: cs(10), weight: .semibold))
                            .foregroundStyle(PaperPalette.inkSecondary)
                        Text("\(Calendar.current.component(.day, from: day))")
                            .font(.system(size: cs(12.5), weight: selected ? .bold : .medium))
                            .monospacedDigit()
                            .foregroundStyle(selected ? Color.white : PaperPalette.ink)
                            .frame(width: cs(20), height: cs(20))
                            .background(Circle().fill(selected ? PaperPalette.ink : Color.clear))
                        Circle()
                            .fill(PaperPalette.ink.opacity(busy ? 0.6 : 0))
                            .frame(width: cs(3.5), height: cs(3.5))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.accessibilityDayFormatter.string(from: day) + (busy ? ", has events" : ""))
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
    }

    // MARK: Timeline

    private var timeline: some View {
        GeometryReader { viewport in
            ScrollView(.vertical, showsIndicators: false) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let featured = featuredID(now: context.date)
                    VStack(alignment: .leading, spacing: cs(7)) {
                        ForEach(items) { item in
                            row(item, featured: item.id == featured, now: context.date)
                        }
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

    private func row(_ item: EventModel, featured: Bool, now: Date) -> some View {
        HStack(alignment: .top, spacing: cs(4)) {
            timeColumn(item)
                .frame(width: cs(33), alignment: .trailing)
                .padding(.top, cs(8))
            if featured {
                featuredCard(item, now: now)
            } else {
                plainCard(item)
            }
        }
    }

    private func timeColumn(_ item: EventModel) -> some View {
        let (time, period) = item.isAllDay ? ("All", Optional("day")) : Self.clock(item.start)
        return VStack(alignment: .trailing, spacing: 0) {
            Text(time)
                .font(.system(size: cs(11), weight: .semibold))
                .monospacedDigit()
            if let period {
                Text(period)
                    .font(.system(size: cs(9.5), weight: .semibold))
                    .foregroundStyle(PaperPalette.inkSecondary)
            }
        }
        .fixedSize()
    }

    /// The current/next event: dark card with a countdown and a Join button.
    private func featuredCard(_ event: EventModel, now: Date) -> some View {
        VStack(alignment: .leading, spacing: cs(3)) {
            Text(event.title)
                .font(.system(size: cs(CardType.body), weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            // One line when it fits; otherwise countdown and calendar on their own lines
            // (never a line that starts with "·").
            ViewThatFits(in: .horizontal) {
                Text(countdown(event, now: now) + " · " + event.calendar.title)
                    .lineLimit(1)
                    .fixedSize()
                VStack(alignment: .leading, spacing: cs(1)) {
                    Text(countdown(event, now: now))
                    Text(event.calendar.title)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: cs(10.5)))
            .foregroundStyle(Color.white.opacity(0.7))
            if let link = Self.meetingLink(event) {
                Button {
                    NSWorkspace.shared.open(link.url)
                } label: {
                    HStack(spacing: cs(5)) {
                        Image(systemName: "video.fill")
                            .font(.system(size: cs(10)))
                        Text(link.label)
                            .font(.system(size: cs(11.5), weight: .semibold))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .padding(.horizontal, cs(10))
                    .padding(.vertical, cs(6))
                    .background(Color.white.opacity(0.16), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, cs(5))
                .help("Open the meeting link")
            }
        }
        .foregroundStyle(Color.white)
        .padding(.vertical, cs(9))
        .padding(.horizontal, cs(8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PaperPalette.ink.opacity(0.92), in: RoundedRectangle(cornerRadius: cs(11), style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { open(event) }
        .help("Open in Calendar")
        .accessibilityElement(children: .contain)
    }

    /// Every other event or reminder: soft card with calendar and duration.
    private func plainCard(_ item: EventModel) -> some View {
        let isReminder = item.type.isReminder
        // The tick sits on the subtitle line so the title gets the card's full width.
        return VStack(alignment: .leading, spacing: cs(2)) {
            Text(item.title)
                .font(.system(size: cs(CardType.body), weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .center, spacing: cs(4)) {
                Text(subtitle(item))
                    .font(.system(size: cs(10.5)))
                    .foregroundStyle(PaperPalette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if isReminder {
                    CheckCircle(isOn: false, tint: PaperPalette.slate, size: 14.5) {
                        Task { await calendar.setReminderCompleted(reminderID: item.id, completed: true) }
                    }
                    .accessibilityLabel("Mark \(item.title) as done")
                }
            }
        }
        .padding(.vertical, cs(8))
        .padding(.horizontal, cs(7))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: cs(11), style: .continuous))
        .opacity(!isReminder && !item.isAllDay && item.eventStatus == .ended ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if !isReminder { open(item) } }
        .help(isReminder ? "" : "Open in Calendar")
        .accessibilityElement(children: .combine)
    }

    private func subtitle(_ item: EventModel) -> String {
        if item.type.isReminder {
            // The default list is called "Reminders"; "Reminder · Reminders" says nothing.
            let list = item.calendar.title
            return list.localizedCaseInsensitiveCompare("Reminders") == .orderedSame ? "Reminder" : "Reminder · " + list
        }
        if item.isAllDay { return item.calendar.title }
        let minutes = Int(item.end.timeIntervalSince(item.start) / 60)
        return item.calendar.title + " · " + Self.duration(minutes)
    }

    private func countdown(_ event: EventModel, now: Date) -> String {
        if event.start <= now {
            return "Ends in " + Self.duration(Int(ceil(event.end.timeIntervalSince(now) / 60)))
        }
        let minutes = Int(ceil(event.start.timeIntervalSince(now) / 60))
        return minutes <= 1 ? "Starting now" : "In " + Self.duration(minutes)
    }

    private func open(_ event: EventModel) {
        if let url = event.calendarAppURL() { NSWorkspace.shared.open(url) }
    }

    // MARK: Footer / menu / access

    private var footer: some View {
        HStack(spacing: cs(4)) {
            Image(systemName: isToday ? "clock" : "calendar")
            Text(footerText)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
            Spacer(minLength: cs(4))
            moreMenu
        }
        .font(.system(size: cs(11.5)))
        .foregroundStyle(PaperPalette.inkSecondary)
    }

    /// What's next today; for other days, which day is showing.
    private var footerText: String {
        guard isToday else { return Self.footerDayFormatter.string(from: selectedDay) }
        let now = Date()
        let timed = items.filter { !$0.isAllDay }
        if let current = timed.first(where: { !$0.type.isReminder && $0.start <= now && $0.end > now }) {
            return "Ends " + current.end.formatted(date: .omitted, time: .shortened)
        }
        if let next = timed.filter({ $0.start > now }).min(by: { $0.start < $1.start }) {
            return "Next · " + next.start.formatted(date: .omitted, time: .shortened)
        }
        return items.isEmpty ? "Free today" : "Done for today"
    }

    private var moreMenu: some View {
        Menu {
            // Which calendars show up here. (Open Calendar / Calendar Settings were removed.)
            if calendar.eventCalendars.isEmpty {
                Text("No calendars").disabled(true)
            } else {
                Section("Show calendars") {
                    ForEach(calendar.eventCalendars, id: \.id) { cal in
                        Button {
                            Task {
                                await calendar.setCalendarSelected(cal, isSelected: !calendar.getCalendarSelected(cal))
                                await calendar.updateBusyDays(from: Date(), days: Self.stripDays)
                            }
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
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: cs(12.5), weight: .semibold))
                .foregroundStyle(PaperPalette.ink)
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
                 ? "Allow Calendar access to see your events."
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

    // MARK: Formatting helpers

    private static let letterFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEE")
        return f
    }()

    private static let accessibilityDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f
    }()

    private static let footerDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return f
    }()

    private static let uses12Hour: Bool =
        DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") ?? false

    private static let hourMinuteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = uses12Hour ? "h:mm" : "HH:mm"
        return f
    }()

    private static let periodFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "a"
        return f
    }()

    /// "3:00" + "PM" on 12-hour clocks, "15:00" + nil on 24-hour clocks.
    private static func clock(_ date: Date) -> (String, String?) {
        (hourMinuteFormatter.string(from: date), uses12Hour ? periodFormatter.string(from: date) : nil)
    }

    /// "45 min", "1 hr", "1 hr 18 min", "2 days".
    private static func duration(_ minutes: Int) -> String {
        let m = max(minutes, 0)
        if m < 60 { return "\(m) min" }
        if m >= 48 * 60 { return "\(m / (24 * 60)) days" }
        let h = m / 60, rest = m % 60
        return rest == 0 ? "\(h) hr" : "\(h) hr \(rest) min"
    }

    /// Video-call link from the event's URL, location or notes.
    private static func meetingLink(_ event: EventModel) -> (url: URL, label: String)? {
        var candidates: [URL] = []
        if let url = event.url { candidates.append(url) }
        let text = [event.location, event.notes].compactMap { $0 }.joined(separator: "\n")
        if !text.isEmpty, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            candidates += detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url)
        }
        for url in candidates {
            let host = url.host?.lowercased() ?? ""
            if host.hasSuffix("meet.google.com") { return (url, "Join Meet") }
            if host.hasSuffix("zoom.us") { return (url, "Join Zoom") }
            if host.hasSuffix("teams.microsoft.com") || host.hasSuffix("teams.live.com") { return (url, "Join Teams") }
            if host.hasSuffix("webex.com") { return (url, "Join Webex") }
            if url.scheme == "facetime" || host.hasSuffix("facetime.apple.com") { return (url, "Join FaceTime") }
        }
        return nil
    }
}
