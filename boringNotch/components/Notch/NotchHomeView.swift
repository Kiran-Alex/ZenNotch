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
        NotchCardsView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Cards sit ~6pt from the notch's edge (the open notch pads its content 12pt).
            .padding(.horizontal, -6)
            .environmentObject(vm)
        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
        .blur(radius: vm.notchState == .closed ? 30 : 0)
    }
}
