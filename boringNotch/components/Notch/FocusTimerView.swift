//
//  FocusTimerView.swift
//  ZenNotch
//
//  Focus timer card: a progress ring with a dot-matrix countdown (tap it for a
//  custom length; shows the end time while running), the task it's for, length
//  chips (Done / Reset once a session is under way) and Start/Pause/Resume.
//

import Defaults
import SwiftUI

struct FocusTimerView: View {
    @Environment(\.notchScale) var notchScale
    /// Card size value scaled for the notch's design proportions and this screen.
    private func cs(_ value: CGFloat) -> CGFloat { value * cardUIScale * notchScale }
    @ObservedObject private var focus = FocusTimerManager.shared
    @ObservedObject private var tasks = TasksManager.shared
    @State private var showCustomTime = false
    @EnvironmentObject var vm: BoringViewModel
    @State private var hostWindow: NSWindow?
    private static let focusOwner = "focus"
    @State private var customText = "45"
    @FocusState private var customFocused: Bool

    private static let presets = [15, 25, 45, 60]

    var body: some View {
        // Read top to bottom: the time, what it's for, how long / when it ends, go.
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            GeometryReader { geo in
                // Cards can be turned off in Settings, so this card may be narrow or very
                // wide. Wide: dial on the left, controls beside it. Otherwise stacked.
                if geo.size.width > geo.size.height * 1.45 {
                    wideLayout(at: timeline.date, size: geo.size)
                } else {
                    stackedLayout(at: timeline.date)
                }
            }
        }
        .overlay {
            if showCustomTime { customTimeSheet }
        }
        .background(WindowReaderView { hostWindow = $0 })
        .onChange(of: tasks.todo) { _, todo in focus.syncLinkedTask(with: todo) }
        // Clicking into another app takes the keyboard away; close the box then.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            guard showCustomTime, let window = note.object as? NSWindow, window === hostWindow else { return }
            closeCustomTime()
        }
        .onDisappear { if showCustomTime { closeCustomTime() } }
    }

    /// Widest the picker, chips and button get, so they don't stretch on a wide card.
    private var controlsMaxWidth: CGFloat { cs(250) }

    private func stackedLayout(at date: Date) -> some View {
        VStack(spacing: 0) {
            // The ring is sized from the space the card actually has, so it never overflows.
            GeometryReader { geo in
                let side = max(min(geo.size.width - cs(18), geo.size.height), 40)
                timerRing(at: date, side: side)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            .padding(.top, cs(20))

            controlStack(at: date)
                .frame(maxWidth: controlsMaxWidth)
                .padding(.top, cs(10))
                .padding(.horizontal, cs(10))
                .padding(.bottom, cs(12))
        }
    }

    private func wideLayout(at date: Date, size: CGSize) -> some View {
        let side = max(size.height - cs(40), 40)
        return HStack(spacing: cs(28)) {
            timerRing(at: date, side: side)
            controlStack(at: date)
                .frame(width: min(controlsMaxWidth, max(size.width - side - cs(80), cs(150))))
        }
        .padding(.top, cs(8))
        .frame(width: size.width, height: size.height)
    }

    /// Task, length / Done row and the main button, top to bottom.
    private func controlStack(at date: Date) -> some View {
        VStack(spacing: 0) {
            taskPicker
            middleRow(at: date)
                .frame(height: cs(24))
                .padding(.top, cs(8))
            controls
                .padding(.top, cs(10))
        }
    }

    // MARK: Timer ring

    private func timerRing(at date: Date, side: CGFloat) -> some View {
        let progress = min(max(focus.progress(at: date), 0), 1)
        let digitWidth = side * 0.7
        let status = statusText(at: date)
        return ZStack {
            TickDial(progress: progress, ticks: 60)
                .animation(.linear(duration: 1), value: progress)

            VStack(spacing: side * 0.06) {
                DotMatrixText(
                    text: Self.clock(focus.remaining(at: date)),
                    color: PaperPalette.ink.opacity(0.85),
                    dim: PaperPalette.ink.opacity(0.07))
                    .frame(width: digitWidth, height: digitWidth * 7 / 25)
                    .accessibilityLabel("\(Int(focus.remaining(at: date) / 60)) minutes left")
                if let status {
                    Text(status)
                        .font(.system(size: cs(11.5), weight: .medium))
                        .foregroundStyle(PaperPalette.inkSecondary)
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity)
                }
            }
        }
        .frame(width: side, height: side)
        // Idle: tap the time for a custom length.
        .contentShape(Circle())
        .onTapGesture {
            guard focus.phase == .idle || focus.phase == .finished else { return }
            openCustomTime()
        }
        .help(focus.phase == .idle ? "Click to set a custom length" : "")
    }

    /// Nothing when idle (the digits and the selected chip already say it).
    private func statusText(at date: Date) -> String? {
        switch focus.phase {
        case .idle: return nil
        case .running:
            return "Ends " + date.addingTimeInterval(focus.remaining(at: date))
                .formatted(date: .omitted, time: .shortened)
        case .paused: return "Paused"
        case .finished: return "Done 🎉"
        }
    }

    // MARK: Task picker

    private var taskPicker: some View {
        Menu {
            Button {
                focus.link(nil)
            } label: {
                if focus.taskID == nil { Label("No task", systemImage: "checkmark") } else { Text("No task") }
            }
            if !tasks.todo.isEmpty { Divider() }
            ForEach(tasks.todo) { item in
                Button {
                    focus.link(item)
                } label: {
                    if item.id == focus.taskID { Label(item.title, systemImage: "checkmark") } else { Text(item.title) }
                }
            }
        } label: {
            VStack(spacing: cs(1)) {
                Text("for")
                    .font(.system(size: cs(10.5)))
                    .foregroundStyle(PaperPalette.inkSecondary)
                HStack(alignment: .firstTextBaseline, spacing: cs(4)) {
                    Text(focus.taskTitle ?? "Pick a task")
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: cs(8), weight: .bold))
                        .foregroundStyle(PaperPalette.inkSecondary)
                }
                .font(.system(size: cs(12.5), weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Focus task: \(focus.taskTitle ?? "none")")
    }

    // MARK: Length / end time

    /// Idle: length chips. Running: Done. Paused or finished: Reset and Done.
    @ViewBuilder
    private func middleRow(at date: Date) -> some View {
        switch focus.phase {
        case .idle:
            // Ink-on-paper, like the dial: plain numbers, a dot under the chosen one.
            HStack(spacing: 0) {
                ForEach(Self.presets, id: \.self) { minutes in
                    let selected = Int((focus.duration / 60).rounded()) == minutes
                    Button {
                        withAnimation(.smooth(duration: 0.15)) { focus.setDuration(minutes: minutes) }
                    } label: {
                        VStack(spacing: cs(2)) {
                            Text("\(minutes)")
                                .font(.system(size: cs(13), weight: selected ? .bold : .medium))
                                .monospacedDigit()
                                .foregroundStyle(selected ? PaperPalette.ink : PaperPalette.inkSecondary)
                            Circle()
                                .fill(PaperPalette.ink.opacity(selected ? 0.85 : 0))
                                .frame(width: cs(4), height: cs(4))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(minutes) minutes")
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
        case .running:
            HStack { doneButton(fill: false) }
                .frame(maxWidth: .infinity)
        case .paused, .finished:
            // Reset goes back to the start; Done closes the session out.
            HStack(spacing: cs(4)) {
                pill(icon: "arrow.counterclockwise", title: "Reset", fill: true) {
                    withAnimation(.smooth(duration: 0.2)) { focus.reset() }
                }
                .help("Reset the timer")
                doneButton(fill: true)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// ✓ Done: ends the session (and marks the linked task done).
    private func doneButton(fill: Bool) -> some View {
        pill(icon: "checkmark", title: "Done", fill: fill) {
            withAnimation(.smooth(duration: 0.2)) { focus.complete() }
        }
        .help(focus.taskID == nil ? "Finish session" : "Finish and mark the task done")
        .accessibilityLabel(focus.taskID == nil ? "Finish session" : "Finish and mark \(focus.taskTitle ?? "task") done")
    }

    /// `fill`: share the row equally with a neighbour, so two pills always fit the card.
    private func pill(icon: String, title: String, fill: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: cs(3)) {
                Image(systemName: icon)
                    .font(.system(size: cs(10), weight: .bold))
                Text(title)
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(.system(size: cs(11.5), weight: .semibold))
            .foregroundStyle(PaperPalette.ink.opacity(0.85))
            .padding(.horizontal, cs(fill ? 4 : 9))
            .frame(maxWidth: fill ? .infinity : nil, maxHeight: .infinity)
            .background(PaperPalette.ink.opacity(0.08), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Controls

    private var controls: some View {
        Button {
            withAnimation(.smooth(duration: 0.2)) { focus.toggle() }
        } label: {
            HStack(spacing: cs(5)) {
                Image(systemName: focus.phase == .running ? "pause.fill" : "play.fill")
                    .font(.system(size: cs(11), weight: .bold))
                Text(primaryLabel)
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(.system(size: cs(14), weight: .semibold))
            .foregroundStyle(PaperPalette.ink.opacity(0.9))
            .frame(maxWidth: .infinity)
            .frame(height: cs(32))
            // A soft ink wash on the paper, instead of a solid black slab.
            .background(PaperPalette.ink.opacity(0.13), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel(primaryLabel)
    }

    private var primaryLabel: String {
        switch focus.phase {
        case .idle: return "Start"
        case .running: return "Pause"
        case .paused: return "Resume"
        case .finished: return "Again"
        }
    }

    private func openCustomTime() {
        customText = String(Int((focus.duration / 60).rounded()))
        // The notch window normally refuses the keyboard; ask for it while typing here.
        (hostWindow as? BoringNotchSkyLightWindow)?.beginKeyboardFocus(owner: Self.focusOwner)
        vm.setKeepOpen(Self.focusOwner, true)
        withAnimation(.smooth(duration: 0.2)) { showCustomTime = true }
    }

    /// Small in-card adjuster for a custom length (no popover: keeps hover behaviour intact).
    /// Type any number of minutes (1–240), or nudge it with − / + (1 min each).
    private var customTimeSheet: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { closeCustomTime() }
            VStack(spacing: cs(8)) {
                Text("Session length")
                    .font(.system(size: cs(11), weight: .semibold))
                HStack(spacing: cs(8)) {
                    stepButton("minus") { setCustom((Int(customText) ?? 0) - 1) }
                    TextField("", text: $customText)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .font(.system(size: cs(18), weight: .semibold).monospacedDigit())
                        .frame(width: cs(46))
                        .padding(.vertical, cs(3))
                        .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: cs(7), style: .continuous))
                        .focused($customFocused)
                        .onSubmit { applyCustom() }
                        .onChange(of: customText) { _, text in
                            // Digits only, no leading zeros (so 0 can't be typed), capped at 240.
                            var digits = String(text.filter(\.isNumber).prefix(3))
                            while digits.hasPrefix("0") { digits.removeFirst() }
                            if let value = Int(digits), value > 240 { digits = "240" }
                            if digits != text { customText = digits }
                        }
                        .accessibilityLabel("Minutes")
                    Text("min")
                        .font(.system(size: cs(11), weight: .medium))
                        .foregroundStyle(PaperPalette.inkSecondary)
                    stepButton("plus") { setCustom((Int(customText) ?? 0) + 1) }
                }
                Button("Set", action: applyCustom)
                    .buttonStyle(.plain)
                    .font(.system(size: cs(11), weight: .semibold))
                    .padding(.horizontal, cs(16))
                    .padding(.vertical, cs(4))
                    .background(Color.black.opacity(0.1), in: Capsule())
                    .disabled((Int(customText) ?? 0) < 1)
                    .opacity((Int(customText) ?? 0) < 1 ? 0.4 : 1)
            }
            .padding(cs(12))
            .background(PaperBackground(tint: PaperPalette.lavender, cornerRadius: cs(14)))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            .transition(.scale(scale: 0.92).combined(with: .opacity))
            .onAppear {
                DispatchQueue.main.async { customFocused = true }
            }
            .onExitCommand { closeCustomTime() }
        }
    }

    private func setCustom(_ minutes: Int) {
        customText = String(min(max(minutes, 1), 240))
    }

    private func applyCustom() {
        guard let minutes = Int(customText) else { return }
        focus.setDuration(minutes: minutes)   // clamps to 1–240
        closeCustomTime()
    }

    private func closeCustomTime() {
        customFocused = false
        (hostWindow as? BoringNotchSkyLightWindow)?.endKeyboardFocus(owner: Self.focusOwner)
        vm.setKeepOpen(Self.focusOwner, false)
        withAnimation(.smooth(duration: 0.2)) { showCustomTime = false }
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: cs(10), weight: .bold))
                .frame(width: cs(22), height: cs(22))
                .background(Color.black.opacity(0.08), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(icon == "plus" ? "Add 5 minutes" : "Remove 5 minutes")
    }

    /// "45:00", or "1:30:00" for an hour or more.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Pieces

private struct ProgressLine: View {
    @Environment(\.notchScale) var notchScale
    /// Card size value scaled for the notch's design proportions and this screen.
    private func cs(_ value: CGFloat) -> CGFloat { value * cardUIScale * notchScale }
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(PaperPalette.ink.opacity(0.15))
                Capsule()
                    .fill(PaperPalette.ink.opacity(0.55))
                    .frame(width: geo.size.width * progress)
            }
        }
        .frame(height: cs(3))
        .accessibilityHidden(true)
    }
}

/// Watch-bezel dial: evenly spaced tick marks; the ones already elapsed are
/// drawn dark, the rest faint. Every fifth tick is a little longer.
private struct TickDial: View {
    var progress: Double
    var ticks: Int

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = side / 2
            let width = max(side * 0.018, 1.5)
            let filled = Int((progress * Double(ticks)).rounded(.down))
            for i in 0..<ticks {
                let major = i % 5 == 0
                let length = side * (major ? 0.085 : 0.06)
                let angle = Double(i) / Double(ticks) * 2 * .pi - .pi / 2
                let dx = cos(angle), dy = sin(angle)
                var path = Path()
                path.move(to: CGPoint(x: center.x + dx * (outer - width / 2),
                                      y: center.y + dy * (outer - width / 2)))
                path.addLine(to: CGPoint(x: center.x + dx * (outer - length),
                                         y: center.y + dy * (outer - length)))
                let on = i < filled
                context.stroke(path,
                               with: .color(PaperPalette.ink.opacity(on ? 0.85 : (major ? 0.22 : 0.14))),
                               style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Digits drawn as a 5×7 grid of dots, like an LED clock, scaled to fit.
struct DotMatrixText: View {
    let text: String
    var color: Color = PaperPalette.ink.opacity(0.62)
    var dim: Color = PaperPalette.ink.opacity(0.035)

    var body: some View {
        Canvas { context, size in
            let glyphs = text.map { Self.glyphs[$0] ?? Self.glyphs[" "]! }
            let columns = glyphs.reduce(0) { $0 + ($1.first?.count ?? 0) } + max(glyphs.count - 1, 0)
            guard columns > 0 else { return }
            let pitch = min(size.width / CGFloat(columns), size.height / 7)
            let dot = pitch * 0.62
            let originX = (size.width - pitch * CGFloat(columns)) / 2
            let originY = (size.height - pitch * 7) / 2

            var col = 0
            for glyph in glyphs {
                let width = glyph.first?.count ?? 0
                for (row, line) in glyph.enumerated() {
                    for (c, char) in line.enumerated() {
                        let rect = CGRect(
                            x: originX + CGFloat(col + c) * pitch + (pitch - dot) / 2,
                            y: originY + CGFloat(row) * pitch + (pitch - dot) / 2,
                            width: dot, height: dot)
                        context.fill(Path(ellipseIn: rect), with: .color(char == "#" ? color : dim))
                    }
                }
                col += width + 1
            }
        }
        .accessibilityHidden(true)
    }

    private static let glyphs: [Character: [String]] = [
        "0": [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
        "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
        "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
        "3": ["#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###."],
        "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
        "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
        "6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
        "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
        "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
        "9": [".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."],
        ":": [".", ".", "#", ".", "#", ".", "."],
        " ": ["..", "..", "..", "..", "..", "..", ".."],
    ]
}
