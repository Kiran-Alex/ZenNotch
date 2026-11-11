//
//  FocusTimerView.swift
//  ZenNotch
//
//  Focus timer card: task picker, dot-matrix countdown, Start/Pause, ✓ (finish
//  and mark the task done) and a "Set time" menu.
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
    @State private var customMinutes = 45

    var body: some View {
        VStack(spacing: 0) {
            taskPicker
                .padding(.top, cs(16))
                .padding(.horizontal, cs(10))

            Spacer(minLength: cs(6))

            // Redraw once a second while counting down.
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                VStack(spacing: cs(6)) {
                    DotMatrixText(text: Self.clock(focus.remaining(at: timeline.date)))
                        .frame(height: cs(24))
                        .padding(.horizontal, cs(18))
                        .accessibilityLabel("\(Int(focus.remaining(at: timeline.date) / 60)) minutes left")
                    Text(statusText)
                        .font(.system(size: cs(11.5), weight: .medium))
                        .foregroundStyle(PaperPalette.inkSecondary)
                    ProgressLine(progress: focus.progress(at: timeline.date))
                        .padding(.horizontal, cs(34))
                        .padding(.top, cs(4))
                }
            }

            Spacer(minLength: cs(6))

            controls
                .padding(.horizontal, cs(10))
            setTimeMenu
                .padding(.top, cs(6))
                .padding(.bottom, cs(12))
        }
        .overlay {
            if showCustomTime { customTimeSheet }
        }
        .onChange(of: tasks.todo) { _, todo in focus.syncLinkedTask(with: todo) }
    }

    private var statusText: String {
        switch focus.phase {
        case .idle: return "Ready"
        case .running: return "Focusing"
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
            HStack(spacing: cs(4)) {
                Text(focus.taskTitle ?? "Pick a task")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: cs(8), weight: .bold))
            }
            .font(.system(size: cs(12), weight: .medium))
            .padding(.horizontal, cs(8))
            .padding(.vertical, cs(4))
            .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: cs(7), style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Focus task: \(focus.taskTitle ?? "none")")
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: cs(6)) {
            Button {
                focus.toggle()
            } label: {
                HStack(spacing: cs(4)) {
                    Image(systemName: focus.phase == .running ? "pause.fill" : "play.fill")
                        .font(.system(size: cs(10), weight: .bold))
                    Text(primaryLabel)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .font(.system(size: cs(13), weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.95))
                .frame(maxWidth: .infinity)
                .frame(height: cs(30))
                .background(PaperPalette.ink.opacity(0.5), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(primaryLabel)

            Button {
                focus.complete()
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: cs(13), weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .frame(width: cs(30), height: cs(30))
                    .background(PaperPalette.ink.opacity(0.5), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(focus.taskID == nil && focus.phase == .idle)
            .opacity(focus.taskID == nil && focus.phase == .idle ? 0.4 : 1)
            .help(focus.taskID == nil ? "Finish session" : "Finish and mark the task done")
            .accessibilityLabel(focus.taskID == nil ? "Finish session" : "Finish and mark \(focus.taskTitle ?? "task") done")
        }
    }

    private var primaryLabel: String {
        switch focus.phase {
        case .idle: return "Start"
        case .running: return "Pause"
        case .paused: return "Resume"
        case .finished: return "Again"
        }
    }

    private var setTimeMenu: some View {
        Menu {
            ForEach([15, 25, 45, 60], id: \.self) { minutes in
                Button {
                    focus.setDuration(minutes: minutes)
                } label: {
                    if Int(focus.duration / 60) == minutes {
                        Label("\(minutes) min", systemImage: "checkmark")
                    } else {
                        Text("\(minutes) min")
                    }
                }
            }
            Button("Custom…") {
                customMinutes = Int(focus.duration / 60)
                withAnimation(.smooth(duration: 0.2)) { showCustomTime = true }
            }
            if focus.phase != .idle {
                Divider()
                Button("Reset timer") { focus.reset() }
            }
        } label: {
            HStack(spacing: cs(4)) {
                Image(systemName: "slider.horizontal.3")
                Text("Set time")
            }
            .font(.system(size: cs(12), weight: .medium))
            .foregroundStyle(PaperPalette.inkSecondary)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        // A new length can't be picked mid-session (only reset is offered then).
        .disabled(focus.phase == .running)
    }

    /// Small in-card adjuster for a custom length (no popover: keeps hover behaviour intact).
    private var customTimeSheet: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.smooth(duration: 0.2)) { showCustomTime = false } }
            VStack(spacing: cs(8)) {
                Text("Session length")
                    .font(.system(size: cs(11), weight: .semibold))
                HStack(spacing: cs(10)) {
                    stepButton("minus") { customMinutes = max(5, customMinutes - 5) }
                    Text("\(customMinutes) min")
                        .font(.system(size: cs(14), weight: .semibold))
                        .monospacedDigit()
                        .frame(minWidth: 52)
                    stepButton("plus") { customMinutes = min(240, customMinutes + 5) }
                }
                Button("Set") {
                    focus.setDuration(minutes: customMinutes)
                    withAnimation(.smooth(duration: 0.2)) { showCustomTime = false }
                }
                .buttonStyle(.plain)
                .font(.system(size: cs(11), weight: .semibold))
                .padding(.horizontal, cs(14))
                .padding(.vertical, cs(4))
                .background(Color.black.opacity(0.1), in: Capsule())
            }
            .padding(cs(12))
            .background(PaperBackground(tint: PaperPalette.lavender, cornerRadius: cs(14)))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            .transition(.scale(scale: 0.92).combined(with: .opacity))
        }
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
