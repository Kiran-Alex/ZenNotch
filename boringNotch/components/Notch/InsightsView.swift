//
//  InsightsView.swift
//  ZenNotch
//
//  Insights tab: a summary card for the last 7 days and a bar chart card
//  (Tasks: completed over planned; Focus: minutes focused per day).
//

import SwiftUI

struct InsightsView: View {
    @ObservedObject private var insights = InsightsManager.shared
    @ObservedObject private var coordinator = BoringViewCoordinator.shared
    @Environment(\.notchScale) private var notchScale

    enum Metric { case tasks, focus }
    @State private var metric: Metric = .tasks
    @State private var selectedDay: Date?

    private func cs(_ value: CGFloat) -> CGFloat { value * cardUIScale * notchScale }

    var body: some View {
        GeometryReader { geo in
            let gap = 7 * notchScale
            HStack(spacing: gap) {
                summaryCard
                    .frame(width: (geo.size.width - gap) * 0.32)
                    .background(PaperBackground(tint: PaperPalette.sage, cornerRadius: 14 * notchScale))
                chartCard
                    .frame(maxWidth: .infinity)
                    .background(PaperBackground(tint: PaperPalette.lavender, cornerRadius: 14 * notchScale))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .foregroundStyle(PaperPalette.ink)
        .environment(\.colorScheme, .light)
        .onAppear { insights.reload() }
        .onChange(of: coordinator.currentView) { _, view in
            if view == .insights { insights.reload() }
        }
    }

    // MARK: Summary card

    private var summaryCard: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Text(headline)
                    .font(.system(size: cs(CardType.title), weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(summaryLine)
                    .font(.system(size: cs(11)))
                    .foregroundStyle(PaperPalette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, cs(3))

                Text("Last 7 days")
                    .font(.system(size: cs(12), weight: .semibold))
                    .padding(.top, cs(14))

                Text("\(insights.completedThisWeek)")
                    .font(.system(size: cs(40), weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .padding(.top, cs(2))
                Text("Tasks completed")
                    .font(.system(size: cs(12)))

                progressBar
                    .padding(.top, cs(10))
                Text("of \(insights.plannedThisWeek) planned")
                    .font(.system(size: cs(10.5)))
                    .foregroundStyle(PaperPalette.inkSecondary)
                    .padding(.top, cs(5))

                StitchLine()
                    .padding(.vertical, cs(10))

                statRow(icon: "timer", label: "Focus time", value: focusDurationLabel(insights.focusThisWeek))
                statRow(icon: "calendar", label: "Active days", value: "\(insights.activeDays) of 7")
                if let best = insights.bestDay {
                    statRow(icon: "star", label: "Best day",
                            value: best.day.formatted(.dateTime.weekday(.abbreviated)) + " · \(best.completed)")
                }
            }
            .padding(.horizontal, cs(12))
            .padding(.top, cs(13))
            .padding(.bottom, cs(10))
        }
    }

    private var progressBar: some View {
        let planned = max(insights.plannedThisWeek, 1)
        let fraction = min(1, Double(insights.completedThisWeek) / Double(planned))
        return GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(PaperPalette.ink.opacity(0.14))
                Capsule().fill(PaperPalette.ink.opacity(0.85))
                    .frame(width: g.size.width * fraction)
            }
        }
        .frame(height: cs(6))
        .accessibilityLabel("\(insights.completedThisWeek) of \(insights.plannedThisWeek) planned tasks completed")
    }

    private func statRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: cs(6)) {
            Image(systemName: icon)
                .font(.system(size: cs(11)))
                .frame(width: cs(15))
            Text(label)
            Spacer(minLength: cs(4))
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
        .font(.system(size: cs(11.5)))
        .padding(.vertical, cs(4))
    }

    private var headline: String {
        let now = insights.completedThisWeek, before = insights.completedLastWeek
        if now == 0 && before == 0 { return "A fresh start" }
        if now > before { return "Momentum is building" }
        if now == before { return "Holding steady" }
        return "A lighter week"
    }

    private var summaryLine: String {
        let now = insights.completedThisWeek, before = insights.completedLastWeek
        let focus = insights.focusThisWeek
        let focusPart = focus >= 60 ? ", with \(focusDurationLabel(focus)) focused" : ""
        let tasks = now == 1 ? "1 task" : "\(now) tasks"
        if now == 0 && before == 0 { return "Finish a task or run a focus session to see your week here." }
        if now > before { return "\(tasks) done, up from \(before) the week before\(focusPart)." }
        if now == before { return "\(tasks) done, the same as the week before\(focusPart)." }
        return "\(tasks) done, down from \(before) the week before\(focusPart)."
    }

    // MARK: Chart card

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                metricPicker
                Spacer(minLength: cs(8))
                Text(rangeLabel)
                    .font(.system(size: cs(10.5)))
                    .foregroundStyle(PaperPalette.inkSecondary)
            }

            BarChart(days: insights.days, metric: metric, selectedDay: $selectedDay, scale: cardUIScale * notchScale)
                .frame(maxHeight: .infinity)
                .padding(.top, cs(10))

            HStack(spacing: cs(14)) {
                legendItem(metric == .tasks ? "Completed" : "Focused", opacity: 0.9)
                if metric == .tasks { legendItem("Planned", opacity: 0.3) }
                Spacer(minLength: cs(8))
                dayMenu
            }
            .padding(.top, cs(8))
        }
        .padding(.horizontal, cs(14))
        .padding(.top, cs(13))
        .padding(.bottom, cs(11))
    }

    private var metricPicker: some View {
        HStack(spacing: cs(2)) {
            metricChip("Tasks", .tasks)
            metricChip("Focus", .focus)
        }
        .padding(cs(2.5))
        .background(Color.black.opacity(0.08), in: Capsule())
        .fixedSize()
    }

    private func metricChip(_ label: String, _ value: Metric) -> some View {
        let selected = metric == value
        return Button {
            withAnimation(.smooth(duration: 0.25)) { metric = value }
        } label: {
            Text(label)
                .font(.system(size: cs(CardType.label), weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white.opacity(0.95) : PaperPalette.ink)
                .padding(.horizontal, cs(14))
                .padding(.vertical, cs(4))
                .background { if selected { Capsule().fill(PaperPalette.ink.opacity(0.62)) } }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var rangeLabel: String {
        guard let first = insights.days.first?.day, let last = insights.days.last?.day else { return "" }
        let style = Date.FormatStyle().day().month(.abbreviated)
        return "\(first.formatted(style)) – \(last.formatted(style))"
    }

    private func legendItem(_ text: String, opacity: Double) -> some View {
        HStack(spacing: cs(5)) {
            RoundedRectangle(cornerRadius: cs(1.5))
                .fill(PaperPalette.ink.opacity(opacity))
                .frame(width: cs(7), height: cs(7))
            Text(text)
        }
        .font(.system(size: cs(10.5)))
    }

    private var dayMenu: some View {
        Menu {
            Button("Whole week") { selectedDay = nil }
            Divider()
            ForEach(insights.days.reversed()) { day in
                Button(dayMenuLabel(day)) { selectedDay = day.day }
            }
        } label: {
            HStack(spacing: cs(3)) {
                Text(selectedSummary)
                Image(systemName: "chevron.down")
                    .font(.system(size: cs(8), weight: .bold))
            }
            .font(.system(size: cs(11), weight: .medium))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func dayMenuLabel(_ day: DayStat) -> String {
        day.day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    /// "Select a day", or the picked day's numbers.
    private var selectedSummary: String {
        guard let day = selectedDay, let stat = insights.days.first(where: { $0.day == day }) else {
            return "Select a day"
        }
        let name = stat.day.formatted(.dateTime.weekday(.abbreviated))
        switch metric {
        case .tasks: return "\(name) · \(stat.completed) of \(stat.planned) done"
        case .focus: return "\(name) · \(focusDurationLabel(stat.focusSeconds)) focused"
        }
    }
}

// MARK: - Bar chart

private struct BarChart: View {
    let days: [DayStat]
    let metric: InsightsView.Metric
    @Binding var selectedDay: Date?
    let scale: CGFloat

    private func cs(_ value: CGFloat) -> CGFloat { value * scale }

    var body: some View {
        let ticks = axisTicks
        let top = ticks.last ?? 1
        VStack(spacing: cs(5)) {
            HStack(alignment: .bottom, spacing: cs(6)) {
                GeometryReader { g in
                    let h = g.size.height
                    ZStack(alignment: .bottom) {
                        // Grid lines at each tick.
                        ForEach(ticks, id: \.self) { tick in
                            Rectangle()
                                .fill(PaperPalette.ink.opacity(tick == 0 ? 0.18 : 0.07))
                                .frame(height: 1)
                                .offset(y: -h * CGFloat(tick) / CGFloat(top))
                        }
                        HStack(alignment: .bottom, spacing: 0) {
                            ForEach(days) { day in
                                bar(day, height: h, top: top)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .frame(width: g.size.width, height: h, alignment: .bottom)
                }
                // Y-axis labels.
                GeometryReader { g in
                    let h = g.size.height
                    ZStack(alignment: .bottomTrailing) {
                        ForEach(ticks, id: \.self) { tick in
                            Text(axisLabel(tick))
                                .font(.system(size: cs(9.5)))
                                .foregroundStyle(PaperPalette.inkSecondary)
                                .monospacedDigit()
                                .offset(y: -h * CGFloat(tick) / CGFloat(top) + cs(5))
                        }
                    }
                    .frame(width: g.size.width, height: h, alignment: .bottomTrailing)
                }
                .frame(width: cs(metric == .focus ? 26 : 14))
            }

            // Day labels.
            HStack(spacing: 0) {
                ForEach(days) { day in
                    let isToday = Calendar.current.isDateInToday(day.day)
                    let isSelected = selectedDay == day.day
                    VStack(spacing: cs(1)) {
                        Text(day.day.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.system(size: cs(11), weight: isToday || isSelected ? .semibold : .regular))
                        Text(day.day.formatted(.dateTime.day()))
                            .font(.system(size: cs(10)))
                            .foregroundStyle(PaperPalette.inkSecondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                Color.clear.frame(width: cs(metric == .focus ? 26 : 14) + cs(6), height: 1)
            }
        }
        .animation(.smooth(duration: 0.3), value: metric)
    }

    private func bar(_ day: DayStat, height: CGFloat, top: Int) -> some View {
        let isSelected = selectedDay == day.day
        let dimmed = selectedDay != nil && !isSelected
        let value = metric == .tasks ? day.completed : day.focusSeconds / 60
        let planned = metric == .tasks ? day.planned : value
        let barHeight = { (v: Int) in max(0, height * CGFloat(v) / CGFloat(max(top, 1))) }
        return ZStack(alignment: .bottom) {
            if metric == .tasks {
                RoundedRectangle(cornerRadius: cs(2.5), style: .continuous)
                    .fill(PaperPalette.ink.opacity(0.22))
                    .frame(height: barHeight(planned))
            }
            RoundedRectangle(cornerRadius: cs(2.5), style: .continuous)
                .fill(PaperPalette.ink.opacity(0.88))
                .frame(height: barHeight(value))
        }
        .frame(width: cs(26))
        .opacity(dimmed ? 0.4 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.smooth(duration: 0.2)) {
                selectedDay = isSelected ? nil : day.day
            }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityText(day))
        .accessibilityAddTraits(.isButton)
    }

    /// 0…max in 4 even steps, rounded to friendly numbers.
    private var axisTicks: [Int] {
        let maxValue = days.map { metric == .tasks ? max($0.planned, $0.completed) : $0.focusSeconds / 60 }.max() ?? 0
        let step: Int
        switch metric {
        case .tasks: step = max(1, Int((Double(max(maxValue, 4)) / 4).rounded(.up)))
        case .focus:
            let raw = Double(max(maxValue, 60)) / 4
            step = [15, 30, 60, 90, 120, 180, 240].first { Double($0) >= raw } ?? Int(raw.rounded(.up))
        }
        return (0...4).map { $0 * step }
    }

    private func axisLabel(_ tick: Int) -> String {
        guard metric == .focus else { return "\(tick)" }
        if tick == 0 { return "0" }
        return tick % 60 == 0 ? "\(tick / 60)h" : "\(tick)m"
    }

    private func accessibilityText(_ day: DayStat) -> String {
        let name = day.day.formatted(.dateTime.weekday(.wide))
        switch metric {
        case .tasks: return "\(name): \(day.completed) of \(day.planned) tasks done"
        case .focus: return "\(name): \(focusDurationLabel(day.focusSeconds)) focused"
        }
    }
}
