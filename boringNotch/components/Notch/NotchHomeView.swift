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
    @Environment(\.notchScale) private var notchScale

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
        // Tasks, focus timer, sticky note and events side by side (Settings > Appearance
        // turns cards on/off; dragging a card's top handle reorders them).
        // Both pages stay mounted side by side (Home left, Insights right,
        // matching the tab order) and slide as one strip. Only offsets animate,
        // so nothing re-lays out mid-switch.
        GeometryReader { geo in
            ZStack {
                page(NotchCardsView(), for: .home, width: geo.size.width)
                page(InsightsView(), for: .insights, width: geo.size.width)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // Rounded like the cards, so a card cut off mid-slide still looks like a card edge.
        .clipShape(RoundedRectangle(cornerRadius: 14 * notchScale, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Cards sit ~6pt from the notch's edge (the open notch pads its content 12pt).
            .padding(.horizontal, -6)
            .environmentObject(vm)
        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
        .blur(radius: vm.notchState == .closed ? 30 : 0)
    }

    private static let pageOrder: [NotchViews] = [.home, .insights]
    /// Gap between the pages while they slide, same as the gap between cards.
    private static let pageGap: CGFloat = 12

    #if DEBUG
    /// Debug snapshots only: freeze the strip partway between pages (0 = Home, 1 = Insights).
    static var debugFrozenPosition: CGFloat?
    #endif

    /// The curve used when switching tabs.
    static let pageSwitchAnimation = Animation.spring(response: 0.42, dampingFraction: 0.88)

    private func page<Content: View>(_ content: Content, for view: NotchViews, width: CGFloat) -> some View {
        let active = coordinator.currentView == view
        let index = Self.pageOrder.firstIndex(of: view) ?? 0
        var current = CGFloat(Self.pageOrder.firstIndex(of: coordinator.currentView) ?? 0)
        #if DEBUG
        if let frozen = Self.debugFrozenPosition { current = frozen }
        #endif
        return content
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .compositingGroup()
            .offset(x: (CGFloat(index) - current) * (width + Self.pageGap))
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
    }
}
