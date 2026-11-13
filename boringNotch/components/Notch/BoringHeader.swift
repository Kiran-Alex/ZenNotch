//
//  BoringHeader.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Defaults
import SwiftUI

struct BoringHeader: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Environment(\.notchScale) private var notchScale

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: 1)

            if vm.notchState == .open {
                // Black block covering the physical notch area.
                Rectangle()
                    .fill(NSScreen.screen(withUUID: coordinator.selectedScreenUUID)?.safeAreaInsets.top ?? 0 > 0 ? .black : .clear)
                    .frame(width: vm.closedNotchSize.width)
                    .mask {
                        NotchShape()
                    }
            }

            HStack(spacing: 0) {
                if vm.notchState == .open {
                    HStack(spacing: 2 * notchScale) {
                        headerTab("Home", icon: "house.fill", page: .home)
                        headerTab("Insights", icon: "chart.bar.fill", page: .insights)
                        if Defaults[.settingsIconInNotch] {
                            Button {
                                DispatchQueue.main.async { SettingsWindowController.shared.showWindow() }
                            } label: {
                                tabLabel("Customize", icon: "gearshape.fill", selected: false, showsTitle: false)
                            }
                            .buttonStyle(.plain)
                            .help("Open Settings")
                            .accessibilityLabel("Open Settings")
                        }
                    }
                    .padding(2 * notchScale)
                    .background(Color.white.opacity(0.03), in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 10 * notchScale)
            .padding(.trailing, 4 * notchScale)
        }
        .opacity(vm.notchState == .closed ? 0 : 1)
        .blur(radius: vm.notchState == .closed ? 20 : 0)
        .environmentObject(vm)
    }

    private func headerTab(_ title: String, icon: String, page: NotchViews) -> some View {
        let selected = coordinator.currentView == page
        return Button {
            withAnimation(NotchHomeView.pageSwitchAnimation) { coordinator.currentView = page }
        } label: {
            tabLabel(title, icon: icon, selected: selected, showsTitle: selected)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func tabLabel(_ title: String, icon: String, selected: Bool, showsTitle: Bool) -> some View {
        let textSize: CGFloat = 10.5 * notchScale
        let iconSize: CGFloat = 10 * notchScale
        let height: CGFloat = 18 * notchScale
        let hPad: CGFloat = 9 * notchScale
        let color: Color = selected ? Color.white.opacity(0.6) : Color.white.opacity(0.28)
        let fill: Color = selected ? Color.white.opacity(0.05) : Color.clear
        return HStack(alignment: .center, spacing: 5 * notchScale) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .medium))
                .frame(width: iconSize + 2, height: height)
            if showsTitle {
                Text(title)
                    .font(.system(size: textSize, weight: .medium))
                    .lineLimit(1)
                    .frame(height: height)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, hPad)
        .frame(height: height + 4 * notchScale)
        .background(Capsule().fill(fill))
        .contentShape(Capsule())
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
