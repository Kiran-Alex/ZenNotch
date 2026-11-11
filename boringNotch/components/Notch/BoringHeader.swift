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
                        headerTab("Workspace", page: .home)
                        headerTab("Insights", page: .insights)
                        if Defaults[.settingsIconInNotch] {
                            Button {
                                DispatchQueue.main.async { SettingsWindowController.shared.showWindow() }
                            } label: {
                                tabLabel("Customize", selected: false)
                            }
                            .buttonStyle(.plain)
                            .help("Open Settings")
                        }
                    }
                    .padding(2 * notchScale)
                    .background(Color.white.opacity(0.08), in: Capsule())
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

    private func headerTab(_ title: String, page: NotchViews) -> some View {
        let selected = coordinator.currentView == page
        return Button {
            withAnimation(.smooth(duration: 0.35)) { coordinator.currentView = page }
        } label: {
            tabLabel(title, selected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func tabLabel(_ title: String, selected: Bool) -> some View {
        let size: CGFloat = 11 * notchScale
        let hPad: CGFloat = 10 * notchScale
        let vPad: CGFloat = 4 * notchScale
        let textColor: Color = selected ? .white : Color.white.opacity(0.6)
        let fill: Color = selected ? Color.white.opacity(0.16) : Color.white.opacity(0.0001)
        return Text(title)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(textColor)
            .padding(.horizontal, hPad)
            .padding(.vertical, vPad)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
