//
//  InsightsView.swift
//  ZenNotch
//
//  Insights tab: a summary card for the chosen range (7 days … all time) and a
//  bar chart card (Tasks: completed over planned; Focus: time focused). Bars are
//  days, weeks, months or years depending on the range. Hovering a bar shows its
//  numbers in the card's top-right corner.
//

import SwiftUI

struct InsightsView: View {
    @ObservedObject private var insights = InsightsManager.shared
    @ObservedObject private var coordinator = BoringViewCoordinator.shared
    @Environment(\.notchScale) private var notchScale

    enum Metric { case tasks, focus }
    @State private var metric: Metric = .tasks
    @State private var hovered: Date?

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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, cs(3))

                Text(insights.range.title)
                    .font(.system(size: cs(12), weight: .semibold))
                    .padding(.top, cs(14))

                Text("\(insights.completed)")
                    .font(.system(size: cs(40), weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .padding(.top, cs(2))
                Text(insights.completed == 1 ? "Task completed" : "Tasks completed")
                    .font(.system(size: cs(12)))

                progressBar
                    .padding(.top, cs(10))
                Text("of \(insights.planned) planned")
                    .font(.system(size: cs(10.5)))
                    .foregroundStyle(PaperPalette.inkSecondary)
                    .padding(.top, cs(5))

                StitchLine()
                    .padding(.vertical, cs(10))

                statRow(icon: "timer", label: "Focus time", value: focusDurationLabel(insights.focusSeconds))
                statRow(icon: "calendar", label: "Active days", value: "\(insights.activeDays) of \(insights.totalDays)")
                if let best = insights.bestBucket {
                    statRow(icon: "star", label: "Best \(unitNoun(best.unit))",
                            value: shortName(best) + " · \(best.completed)")
                }
            }
            .padding(.horizontal, cs(12))
            .padding(.top, cs(13))
            .padding(.bottom, cs(10))
        }
        .animation(.smooth(duration: 0.25), value: insights.range)
    }

    private var progressBar: some View {
        let planned = max(insights.planned, 1)
        let fraction = min(1, Double(insights.completed) / Double(planned))
        return GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(PaperPalette.ink.opacity(0.14))
                Capsule().fill(PaperPalette.ink.opacity(0.85))
                    .frame(width: g.size.width * fraction)
            }
        }
        .frame(height: cs(12))
        .accessibilityElement()
        .accessibilityLabel("\(insights.completed) of \(insights.planned) planned tasks completed")
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
        let now = insights.completed
        guard let before = insights.previousCompleted else {
            return now == 0 ? "A fresh start" : "Your track record"
        }
        if now == 0 && before == 0 { return "A fresh start" }
        if now > before { return "Momentum is building" }
        if now == before { return "Holding steady" }
        return "A lighter stretch"
    }

    private var summaryLine: String {
        let now = insights.completed
        let focus = insights.focusSeconds
        let focusPart = focus >= 60 ? ", with \(focusDurationLabel(focus)) focused" : ""
        let tasks = now == 1 ? "1 task" : "\(now) tasks"
        guard let before = insights.previousCompleted else {
            if now == 0 && focus < 60 { return "Finish a task or run a focus session to see your progress here." }
            let since = insights.rangeStart.formatted(.dateTime.month(.abbreviated).year())
            return "\(tasks) done since \(since)\(focusPart)."
        }
        if now == 0 && before == 0 && focus < 60 {
            return "Finish a task or run a focus session to see your progress here."
        }
        let period = insights.range.previousPhrase
        if now > before { return "\(tasks) done, up from \(before) the \(period) before\(focusPart)." }
        if now == before { return "\(tasks) done, the same as the \(period) before\(focusPart)." }
        return "\(tasks) done, down from \(before) the \(period) before\(focusPart)."
    }

    // MARK: Chart card

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                metricPicker
                Spacer(minLength: cs(8))
                Text(cornerText)
                    .font(.system(size: cs(10.5), weight: hovered == nil ? .regular : .semibold))
                    .foregroundStyle(hovered == nil ? PaperPalette.inkSecondary : PaperPalette.ink)
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.opacity)
            }

            BarChart(buckets: insights.buckets, unit: insights.unit, metric: metric,
                     hovered: $hovered, scale: cardUIScale * notchScale)
                .frame(maxHeight: .infinity)
                .padding(.top, cs(10))

            HStack(spacing: cs(14)) {
                legendItem(metric == .tasks ? "Completed" : "Focused", opacity: 0.9)
                if metric == .tasks { legendItem("Planned", opacity: 0.3) }
                Spacer(minLength: cs(8))
                rangePicker
            }
            .padding(.top, cs(8))
        }
        .padding(.horizontal, cs(14))
        .padding(.top, cs(13))
        .padding(.bottom, cs(11))
    }

    private var metricPicker: some View {
        HStack(spacing: cs(2)) {
            chip("Tasks", selected: metric == .tasks) { metric = .tasks }
            chip("Focus", selected: metric == .focus) { metric = .focus }
        }
        .padding(cs(2.5))
        .background(Color.black.opacity(0.08), in: Capsule())
        .fixedSize()
    }

    private var rangePicker: some View {
        HStack(spacing: cs(1)) {
            ForEach(InsightsRange.allCases) { range in
                chip(range.chip, selected: insights.range == range, compact: true) {
                    hovered = nil
                    insights.range = range
                }
                .help(range.title)
            }
        }
        .padding(cs(2.5))
        .background(Color.black.opacity(0.08), in: Capsule())
        .fixedSize()
    }

    private func chip(_ label: String, selected: Bool, compact: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.25)) { action() }
        } label: {
            Text(label)
                .font(.system(size: cs(CardType.label), weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white.opacity(0.95) : PaperPalette.ink)
                .padding(.horizontal, cs(compact ? 9 : 14))
                .padding(.vertical, cs(4))
                .background { if selected { Capsule().fill(PaperPalette.ink.opacity(0.62)) } }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
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

    /// The range's dates, or the hovered bar's numbers.
    private var cornerText: String {
        if let start = hovered, let bucket = insights.buckets.first(where: { $0.start == start }) {
            let name = longName(bucket)
            switch metric {
            case .tasks:
                if bucket.planned == 0 { return "\(name) · nothing planned" }
                return "\(name) · \(bucket.completed) of \(bucket.planned) done"
            case .focus:
                if bucket.focusSeconds < 60 { return "\(name) · no focus time" }
                return "\(name) · \(focusDurationLabel(bucket.focusSeconds)) focused"
            }
        }
        guard let first = insights.buckets.first?.start else { return "" }
        let last = Date()
        switch insights.unit {
        case .day, .week:
            let style = Date.FormatStyle().day().month(.abbreviated)
            return "\(first.formatted(style)) – \(last.formatted(style))"
        case .month, .year:
            if insights.range == .all {
                return "Since \(first.formatted(.dateTime.month(.abbreviated).year()))"
            }
            let style = Date.FormatStyle().month(.abbreviated).year()
            return "\(first.formatted(style)) – \(last.formatted(style))"
        }
    }

    private func unitNoun(_ unit: InsightsBucketUnit) -> String {
        switch unit {
        case .day: "day"
        case .week: "week"
        case .month: "month"
        case .year: "year"
        }
    }

    /// For the "Best …" row: "Mon 9", "3 Nov", "Nov 2025", "2025".
    private func shortName(_ b: InsightsBucket) -> String {
        switch b.unit {
        case .day:
            return insights.range == .week
                ? b.start.formatted(.dateTime.weekday(.abbreviated).day())
                : b.start.formatted(.dateTime.day().month(.abbreviated))
        case .week: return b.start.formatted(.dateTime.day().month(.abbreviated))
        case .month: return b.start.formatted(.dateTime.month(.abbreviated).year())
        case .year: return b.start.formatted(.dateTime.year())
        }
    }

    /// For the hover readout: "Mon 9 Nov", "Week of 3 Nov", "Nov 2025", "2025".
    private func longName(_ b: InsightsBucket) -> String {
        switch b.unit {
        case .day: return b.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        case .week: return "Week of " + b.start.formatted(.dateTime.day().month(.abbreviated))
        case .month: return b.start.formatted(.dateTime.month(.wide).year())
        case .year: return b.start.formatted(.dateTime.year())
        }
    }
}

// MARK: - Bar chart

private struct BarChart: View {
    let buckets: [InsightsBucket]
    let unit: InsightsBucketUnit
    let metric: InsightsView.Metric
    @Binding var hovered: Date?
    let scale: CGFloat

    private func cs(_ value: CGFloat) -> CGFloat { value * scale }
    private var axisWidth: CGFloat { cs(metric == .focus ? 30 : 18) }

    var body: some View {
        let ticks = axisTicks
        let top = ticks.last ?? 1
        VStack(spacing: cs(5)) {
            HStack(alignment: .bottom, spacing: cs(6)) {
                GeometryReader { g in
                    let h = g.size.height
                    let slot = g.size.width / CGFloat(max(buckets.count, 1))
                    let barWidth = min(cs(26), slot * (buckets.count > 14 ? 0.7 : 0.6))
                    ZStack(alignment: .bottom) {
                        ForEach(ticks, id: \.self) { tick in
                            Rectangle()
                                .fill(PaperPalette.ink.opacity(tick == 0 ? 0.18 : 0.07))
                                .frame(height: 1)
                                .offset(y: -h * CGFloat(tick) / CGFloat(top))
                        }
                        HStack(alignment: .bottom, spacing: 0) {
                            ForEach(buckets) { bucket in
                                bar(bucket, height: h, top: top, width: barWidth)
                                    .frame(width: slot)
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
                                .fixedSize()
                                .offset(y: -h * CGFloat(tick) / CGFloat(top) + cs(5))
                        }
                    }
                    .frame(width: g.size.width, height: h, alignment: .bottomTrailing)
                }
                .frame(width: axisWidth)
            }

            // X-axis labels, thinned out so they never collide. The newest bar is always labelled.
            HStack(spacing: 0) {
                ForEach(Array(buckets.enumerated()), id: \.element.id) { index, bucket in
                    let shown = (buckets.count - 1 - index) % labelStride == 0
                    let emphasized = bucket.containsToday || hovered == bucket.start
                    VStack(spacing: cs(1)) {
                        Text(shown ? topLabel(bucket) : " ")
                            .font(.system(size: cs(11), weight: emphasized ? .semibold : .regular))
                        Text(shown ? bottomLabel(bucket) : " ")
                            .font(.system(size: cs(10)))
                            .foregroundStyle(PaperPalette.inkSecondary)
                    }
                    .fixedSize()
                    .frame(maxWidth: .infinity)
                }
                Color.clear.frame(width: axisWidth + cs(6), height: 1)
            }
        }
        .animation(.smooth(duration: 0.3), value: metric)
        .animation(.smooth(duration: 0.3), value: buckets)
    }

    private var labelStride: Int {
        switch buckets.count {
        case ..<14: unit == .week ? 2 : 1
        case ..<20: 2
        default: 5
        }
    }

    private func topLabel(_ b: InsightsBucket) -> String {
        switch unit {
        case .day:
            return buckets.count <= 7
                ? b.start.formatted(.dateTime.weekday(.abbreviated))
                : b.start.formatted(.dateTime.day())
        case .week: return b.start.formatted(.dateTime.day())
        case .month: return b.start.formatted(.dateTime.month(.abbreviated))
        case .year: return b.start.formatted(.dateTime.year())
        }
    }

    private func bottomLabel(_ b: InsightsBucket) -> String {
        switch unit {
        case .day:
            return buckets.count <= 7
                ? b.start.formatted(.dateTime.day())
                : b.start.formatted(.dateTime.month(.abbreviated))
        case .week: return b.start.formatted(.dateTime.month(.abbreviated))
        case .month: return b.start.formatted(.dateTime.year())
        case .year: return " "
        }
    }

    private func bar(_ bucket: InsightsBucket, height: CGFloat, top: Int, width: CGFloat) -> some View {
        let isHovered = hovered == bucket.start
        let dimmed = hovered != nil && !isHovered
        let value = metric == .tasks ? bucket.completed : bucket.focusSeconds / 60
        let planned = metric == .tasks ? bucket.planned : value
        let barHeight = { (v: Int) in max(0, height * CGFloat(v) / CGFloat(max(top, 1))) }
        let radius = min(cs(2.5), width / 3)
        return ZStack(alignment: .bottom) {
            if metric == .tasks {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(PaperPalette.ink.opacity(0.22))
                    .frame(height: barHeight(planned))
            }
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(PaperPalette.ink.opacity(0.88))
                .frame(height: barHeight(value))
        }
        .frame(width: width)
        .opacity(dimmed ? 0.4 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) {
                if inside { hovered = bucket.start } else if hovered == bucket.start { hovered = nil }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityText(bucket))
    }

    /// 0…max in 4 even, friendly steps.
    private var axisTicks: [Int] {
        let maxValue = buckets.map { metric == .tasks ? max($0.planned, $0.completed) : $0.focusSeconds / 60 }.max() ?? 0
        let step: Int
        switch metric {
        case .tasks:
            step = niceStep(Double(max(maxValue, 4)) / 4, from: [1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000])
        case .focus:
            step = niceStep(Double(max(maxValue, 60)) / 4,
                            from: [15, 30, 60, 90, 120, 180, 240, 300, 600, 900, 1200, 1800, 3000, 6000, 12000])
        }
        return (0...4).map { $0 * step }
    }

    private func niceStep(_ raw: Double, from steps: [Int]) -> Int {
        steps.first { Double($0) >= raw } ?? Int(raw.rounded(.up))
    }

    private func axisLabel(_ tick: Int) -> String {
        guard metric == .focus else { return "\(tick)" }
        if tick == 0 { return "0" }
        return tick % 60 == 0 ? "\(tick / 60)h" : "\(tick)m"
    }

    private func accessibilityText(_ b: InsightsBucket) -> String {
        let name: String = switch unit {
        case .day: b.start.formatted(.dateTime.weekday(.wide).day().month(.wide))
        case .week: "Week of " + b.start.formatted(.dateTime.day().month(.wide))
        case .month: b.start.formatted(.dateTime.month(.wide).year())
        case .year: b.start.formatted(.dateTime.year())
        }
        switch metric {
        case .tasks: return "\(name): \(b.completed) of \(b.planned) tasks done"
        case .focus: return "\(name): \(focusDurationLabel(b.focusSeconds)) focused"
        }
    }
}
