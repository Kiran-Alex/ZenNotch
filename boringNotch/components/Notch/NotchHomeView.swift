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
        // Both pages stay mounted and slide horizontally (Workspace on the left,
        // Insights on the right, matching the tab order). Only offsets animate,
        // so nothing re-lays out mid-switch.
        GeometryReader { geo in
            ZStack {
                page(NotchCardsView(), for: .home, width: geo.size.width)
                page(InsightsView(), for: .insights, width: geo.size.width)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Cards sit ~6pt from the notch's edge (the open notch pads its content 12pt).
            .padding(.horizontal, -6)
            .environmentObject(vm)
        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
        .blur(radius: vm.notchState == .closed ? 30 : 0)
    }

    private static let pageOrder: [NotchViews] = [.home, .insights]

    private func page<Content: View>(_ content: Content, for view: NotchViews, width: CGFloat) -> some View {
        let active = coordinator.currentView == view
        let index = Self.pageOrder.firstIndex(of: view) ?? 0
        let current = Self.pageOrder.firstIndex(of: coordinator.currentView) ?? 0
        // Pages one gap apart so the incoming card edge doesn't touch the outgoing one.
        let offset = CGFloat(index - current) * (width + 12)
        return content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(x: offset)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
    }
}
