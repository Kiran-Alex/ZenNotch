//
//  NotchHomeView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-18.
//  Modified by Harsh Vardhan Goswami & Richard Kunkli & Mustafa Ramadan
//

import Defaults
import SwiftUI

// MARK: - Main View

struct NotchHomeView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var coordinator = BoringViewCoordinator.shared

    var body: some View {
        Group {
            if !coordinator.firstLaunch {
                mainContent
            }
        }
        // simplified: use a straightforward opacity transition
        .transition(.opacity)
    }

    private var mainContent: some View {
        // Tasks, focus timer, notepad and events side by side (Settings > Appearance
        // turns cards on/off; dragging a card's top handle reorders them).
        // Both pages stay mounted (no re-layout mid-switch). Switching nudges the
        // pages a short way in the tab's direction while the old one fades out
        // quickly and the new one fades in just after, so they never overlap
        // half-transparent.
        ZStack {
            page(NotchCardsView(), for: .home)
            page(InsightsView(), for: .insights)
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Cards sit ~6pt from the notch's edge (the open notch pads its content 12pt).
            .padding(.horizontal, -6)
            .environmentObject(vm)
        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
        .blur(radius: vm.notchState == .closed ? 30 : 0)
    }

    private static let pageOrder: [NotchViews] = [.home, .insights]

    private func page<Content: View>(_ content: Content, for view: NotchViews) -> some View {
        let active = coordinator.currentView == view
        let index = Self.pageOrder.firstIndex(of: view) ?? 0
        let current = Self.pageOrder.firstIndex(of: coordinator.currentView) ?? 0
        // Inactive pages wait a short distance off to their side.
        let offset = CGFloat(index - current) * 36
        return content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .compositingGroup()
            // Movement: a soft spring. Fade: old page out fast, new page in just after.
            .animation(.spring(response: 0.38, dampingFraction: 0.9)) { $0.offset(x: offset) }
            .animation(active ? .easeOut(duration: 0.22).delay(0.07) : .easeIn(duration: 0.12)) {
                $0.opacity(active ? 1 : 0)
            }
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
    }
}
