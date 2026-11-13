//
//  ContentView.swift
//  boringNotchApp
//
//  Created by Harsh Vardhan Goswami  on 02/08/24
//  Modified by Richard Kunkli on 24/08/2024.
//

import Combine
import Defaults
import KeyboardShortcuts
import SwiftUI
import SwiftUIIntrospect

@MainActor
struct ContentView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var focus = FocusTimerManager.shared
    @ObservedObject var tasks = TasksManager.shared
    @State private var hoverTask: Task<Void, Never>?
    @State private var isHovering: Bool = false
    @State private var clickMonitors: [Any] = []

    @State private var gestureProgress: CGFloat = .zero

    @State private var haptics: Bool = false

    @Default(.showNotHumanFace) var showNotHumanFace

    // Shared interactive spring for movement/resizing to avoid conflicting animations
    private let animationSpring = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)

    private let extendedHoverPadding: CGFloat = 30
    private let zeroHeightHoverPadding: CGFloat = 10

    private var topCornerRadius: CGFloat {
       ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.top
                : cornerRadiusInsets.closed.top
    }

    @State private var borderPulse: Double = 0
    @State private var sweepAngle: Double = 0
    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.bottom
                : cornerRadiusInsets.closed.bottom
        )
    }

    private var computedChinWidth: CGFloat {
        var chinWidth: CGFloat = vm.closedNotchSize.width

        if showsFocusActivity {
            chinWidth += 2 * focusActivitySideWidth + 22
        } else if vm.notchState == .closed && Defaults[.showNotHumanFace] && !vm.hideOnClosed {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        }

        return chinWidth
    }

    var body: some View {
        // Calculate scale based on gesture progress only
        let gestureScale: CGFloat = {
            guard gestureProgress != 0 else { return 1.0 }
            let scaleFactor = 1.0 + gestureProgress * 0.01
            return max(0.6, scaleFactor)
        }()
        
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                let mainLayout = NotchLayout()
                    // When open, fill the full open height so the black shape stays attached to the
                    // top edge even if the content is short (otherwise the frame below centers it).
                    .frame(maxHeight: vm.notchState == .open ? .infinity : nil, alignment: .top)
                    .padding(
                        .horizontal,
                        vm.notchState == .open
                        ? Defaults[.cornerRadiusScaling]
                        ? (cornerRadiusInsets.opened.top) : (cornerRadiusInsets.opened.bottom)
                        : cornerRadiusInsets.closed.bottom
                    )
                    .padding([.horizontal, .bottom], vm.notchState == .open ? 12 : 0)
                    .background(.black)
                    .clipShape(currentNotchShape)
                    .overlay {
                        // Light sweep shown once after onboarding finishes.
                        let comet = AngularGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .clear, location: 0.6),
                                .init(color: PaperPalette.lavender, location: 0.9),
                                .init(color: .white, location: 1.0),
                            ],
                            center: .center,
                            angle: .degrees(sweepAngle)
                        )
                        ZStack {
                            currentNotchShape.stroke(comet, lineWidth: 7).blur(radius: 7)
                            currentNotchShape.stroke(comet, lineWidth: 3)
                        }
                        .opacity(borderPulse)
                        .allowsHitTesting(false)
                    }
                    .onChange(of: vm.notchState) { _, newState in
                        // Hovering/opening means they found the notch: stop the comet
                        // and clear any due alert (the task is right there in the list).
                        if newState == .open {
                            if borderPulse > 0 {
                                withAnimation(.easeOut(duration: 0.25)) { borderPulse = 0 }
                            }
                            tasks.dismissTaskAlert()
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .onboardingFinished)) { _ in
                        runSweep(laps: 3, after: 0.4)
                    }
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .shadow(
                        color: ((vm.notchState == .open || isHovering) && Defaults[.enableShadow])
                            ? .black.opacity(0.7) : .clear, radius: Defaults[.cornerRadiusScaling] ? 6 : 4
                    )
                    .padding(
                        .bottom,
                        vm.effectiveClosedNotchHeight == 0 ? 10 : 0
                    )
                
                mainLayout
                    .frame(height: vm.notchState == .open ? vm.notchSize.height : nil, alignment: .top)
                    .conditionalModifier(true) { view in
                        let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
                        let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
                        
                        return view
                            .animation(vm.notchState == .open ? openAnimation : closeAnimation, value: vm.notchState)
                            .animation(.smooth, value: gestureProgress)
                    }
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        handleHover(hovering)
                    }
                    .onTapGesture {
                        doOpen()
                    }
                    .onAppear { installClickOutsideMonitors() }
                    .onDisappear { removeClickOutsideMonitors() }
                    // Two-finger swipe down opens the closed notch (no setting for it).
                    .conditionalModifier(true) { view in
                        view
                            .panGesture(direction: .down) { translation, phase in
                                handleDownGesture(translation: translation, phase: phase)
                            }
                    }
                    .onChange(of: vm.notchState) { _, newState in
                        if newState == .closed && isHovering {
                            withAnimation {
                                isHovering = false
                            }
                        }
                    }
                    .onChange(of: vm.isKeptOpen) { _, keptOpen in
                        // Typing/dragging finished with the pointer already outside: close now.
                        if Defaults[.notchInteractionMode] == .hover && !keptOpen && !isHovering && vm.notchState == .open {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .seconds(Defaults[.closeDelay]))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if !self.isHovering && !self.vm.isKeptOpen && self.vm.notchState == .open {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .sensoryFeedback(.alignment, trigger: haptics)
                    .contextMenu {
                        Button("Settings") {
                            DispatchQueue.main.async {
                                SettingsWindowController.shared.showWindow()
                            }
                        }
                        .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
                        //                    Button("Edit") { // Doesnt work....
                        //                        let dn = DynamicNotch(content: EditPanelView())
                        //                        dn.toggle()
                        //                    }
                        //                    .keyboardShortcut("E", modifiers: .command)
                    }
                if vm.chinHeight > 0 {
                    Rectangle()
                        .fill(Color.black.opacity(0.01))
                        .frame(width: computedChinWidth, height: vm.chinHeight)
                }
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: windowSize.width, maxHeight: windowSize.height, alignment: .top)
        .compositingGroup()
        .scaleEffect(
            x: gestureScale,
            y: gestureScale,
            anchor: .top
        )
        .animation(.smooth, value: gestureProgress)
        .preferredColorScheme(.dark)
        .environmentObject(vm)
        // Text, icons and spacing inside the notch follow the screen's size.
        .environment(\.notchScale, notchScale(screenUUID: vm.screenUUID))
    }

    @ViewBuilder
    func NotchLayout() -> some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading) {
                do {
                    if showsFocusActivity {
                          FocusLiveActivity()
                       } else if vm.notchState == .closed && Defaults[.showNotHumanFace] && !vm.hideOnClosed {
                          BoringFaceAnimation()
                       } else if vm.notchState == .open {
                           BoringHeader()
                               .frame(height: max(24, vm.effectiveClosedNotchHeight))
                               .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
                       } else {
                           Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: vm.effectiveClosedNotchHeight)
                       }

                  }
              }
              .zIndex(2)
            if showsTaskAlert, let alert = tasks.taskAlert {
                // Drops straight down from the closed notch, same width (no sideways growth).
                TaskAlertCard(alert: alert, width: vm.closedNotchSize.width - 20)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
            }
            if vm.notchState == .open {
                VStack {
                    NotchHomeView()
                }
                .transition(
                    .scale(scale: 0.8, anchor: .top)
                    .combined(with: .opacity)
                    .animation(.smooth(duration: 0.35))
                )
                .zIndex(1)
                .allowsHitTesting(vm.notchState == .open)
                .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
            }
        }
    }

    // MARK: Comet sweep

    @State private var sweepToken = 0

    /// Runs the lavender comet around the notch outline for `laps` laps.
    private func runSweep(laps: Int, after delay: Double) {
        sweepToken += 1
        let token = sweepToken
        let lap = 1.4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard token == sweepToken else { return }
            sweepAngle = 0
            withAnimation(.easeIn(duration: 0.2)) { borderPulse = 1 }
            withAnimation(.linear(duration: lap).repeatCount(laps, autoreverses: false)) {
                sweepAngle = 360
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + lap * Double(laps) - 0.2) {
                guard token == sweepToken else { return } // a newer sweep took over
                withAnimation(.easeOut(duration: 0.4)) { borderPulse = 0 }
            }
        }
    }

    // MARK: Task alert (closed notch)

    private var showsTaskAlert: Bool {
        vm.notchState == .closed && tasks.taskAlert != nil && !vm.hideOnClosed
    }

    // MARK: Focus live activity (closed notch)

    private var showsFocusActivity: Bool {
        vm.notchState == .closed && focus.isActive && !vm.hideOnClosed
            && !Defaults[.hiddenCards].contains(.focus)
    }

    private let focusActivitySideWidth: CGFloat = 46

    /// Timer icon left of the notch, countdown right of it, while a session runs.
    @ViewBuilder
    func FocusLiveActivity() -> some View {
        HStack(spacing: 0) {
            Image(systemName: focus.phase == .paused ? "pause.fill" : "timer")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PaperPalette.lavender)
                .frame(width: focusActivitySideWidth, alignment: .leading)
                .padding(.leading, 6)
            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width - 10)
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                Text(FocusTimerView.clock(focus.remaining(at: timeline.date)))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(focus.phase == .paused ? Color.gray : Color.white)
            }
            .frame(width: focusActivitySideWidth, alignment: .trailing)
            .padding(.trailing, 6)
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Focus timer \(focus.phase == .paused ? "paused" : "running")")
    }

    @ViewBuilder
    func BoringFaceAnimation() -> some View {
        HStack {
            HStack {
                Rectangle()
                    .fill(.clear)
                    .frame(
                        width: max(0, vm.effectiveClosedNotchHeight - 12),
                        height: max(0, vm.effectiveClosedNotchHeight - 12)
                    )
                Rectangle()
                    .fill(.black)
                    .frame(width: vm.closedNotchSize.width - 20)
                MinimalFaceFeatures()
            }
        }.frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    private func doOpen() {
        // Do not open during onboarding: the content is hidden until it is finished.
        if coordinator.firstLaunch { return }
        withAnimation(animationSpring) {
            vm.open()
        }
    }

    // MARK: - Hover Management

    private func handleHover(_ hovering: Bool) {
        if coordinator.firstLaunch { return }
        hoverTask?.cancel()
        // Tap mode: hovering never opens or closes the notch, it only drives the hover visuals.
        let hoverControlsNotch = Defaults[.notchInteractionMode] == .hover
        if hovering {
            withAnimation(animationSpring) {
                isHovering = true
            }
            
            if vm.notchState == .closed && Defaults[.enableHaptics] {
                haptics.toggle()
            }
            
            // While a task alert is down, hovering must not open the notch, or the
            // pointer could never reach the Snooze / Done buttons.
            guard vm.notchState == .closed, hoverControlsNotch, tasks.taskAlert == nil else { return }
            
            hoverTask = Task {
                try? await Task.sleep(for: .seconds(Defaults[.minimumHoverDuration]))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    guard self.vm.notchState == .closed,
                          self.isHovering else { return }
                    
                    self.doOpen()
                }
            }
        } else {
            hoverTask = Task {
                try? await Task.sleep(for: .seconds(Defaults[.closeDelay]))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    withAnimation(animationSpring) {
                        self.isHovering = false
                    }
                    
                    // Stay open while something needs it (typing, dragging); closes when it ends.
                    if hoverControlsNotch && self.vm.notchState == .open && !self.vm.isKeptOpen {
                        self.vm.close()
                    }
                }
            }
        }
    }
    // MARK: - Tap mode: click outside closes
    private func installClickOutsideMonitors() {
        guard clickMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        let vm = self.vm
        let closeIfOutside: () -> Void = {
            guard Defaults[.notchInteractionMode] == .tap,
                  vm.notchState == .open,
                  !vm.isKeptOpen,
                  !vm.isMouseHovering() else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 1.0)) {
                vm.close()
            }
        }
        // Clicks in other apps.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in closeIfOutside() }) {
            clickMonitors.append(global)
        }
        // Clicks in our own (larger, mostly transparent) window but outside the notch.
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            closeIfOutside()
            return event
        }) {
            clickMonitors.append(local)
        }
    }
    private func removeClickOutsideMonitors() {
        clickMonitors.forEach { NSEvent.removeMonitor($0) }
        clickMonitors.removeAll()
    }

    // MARK: - Gesture Handling

    private func handleDownGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .closed else { return }

        if phase == .ended {
            withAnimation(animationSpring) { gestureProgress = .zero }
            return
        }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * 20
        }

        if translation > Defaults[.gestureSensitivity] {
            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
            doOpen()
        }
    }

}

#Preview {
    let vm = BoringViewModel()
    vm.open()
    return ContentView()
        .environmentObject(vm)
        .frame(width: vm.notchSize.width, height: vm.notchSize.height)
}

// MARK: - Task alert card

/// The paper card that drops down from the closed notch for a heads-up or a due task.
struct TaskAlertCard: View {
    let alert: TaskAlert
    let width: CGFloat
    @ObservedObject private var tasks = TasksManager.shared
    @Default(.taskAlertSnoozeMinutes) private var snoozeMinutes

    private var isDue: Bool { alert.kind == .due }
    private var tint: Color { isDue ? PaperPalette.mustard : PaperPalette.lavender }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: isDue ? "bell.fill" : "clock.fill")
                    .symbolEffect(.bounce, options: .repeat(isDue ? 3 : 1), value: alert.firedAt)
                TimelineView(.periodic(from: .now, by: 15)) { timeline in
                    Text(label(at: timeline.date))
                }
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(PaperPalette.inkSecondary)

            Text(alert.item.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(PaperPalette.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                if isDue {
                    pill("Snooze", systemImage: "moon.zzz.fill", filled: false) { tasks.snoozeTaskAlert() }
                        .help("Remind me again in \(snoozeMinutes) min")
                        .accessibilityLabel("Snooze \(snoozeMinutes) minutes")
                } else {
                    pill("Dismiss", systemImage: nil, filled: false) { tasks.dismissTaskAlert() }
                }
                pill("Done", systemImage: "checkmark", filled: true) { tasks.completeTaskAlert() }
                    .accessibilityLabel("Mark \(alert.item.title) done")
            }
        }
        .padding(10)
        .frame(width: width, alignment: .leading)
        .background(PaperBackground(tint: tint, cornerRadius: 12))
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .contain)
    }

    private func label(at now: Date) -> String {
        guard !isDue, let due = alert.item.dueTime else { return "Due now" }
        let minutes = Int(ceil(due.timeIntervalSince(now) / 60))
        return minutes <= 0 ? "Due now" : "Due in \(minutes) min"
    }

    private func pill(_ title: String, systemImage: String?, filled: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let systemImage { Image(systemName: systemImage).imageScale(.small) }
                Text(title)
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(filled ? Color.white : PaperPalette.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(Capsule().fill(filled ? PaperPalette.ink : PaperPalette.ink.opacity(0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
