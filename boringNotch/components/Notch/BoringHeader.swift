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
            // Left side intentionally empty (tabs, mirror and HUD were removed).
            Spacer()
                .frame(maxWidth: .infinity)

            if vm.notchState == .open {
                // Black block covering the physical notch area.
                Rectangle()
                    .fill(NSScreen.screen(withUUID: coordinator.selectedScreenUUID)?.safeAreaInsets.top ?? 0 > 0 ? .black : .clear)
                    .frame(width: vm.closedNotchSize.width)
                    .mask {
                        NotchShape()
                    }
            }

            HStack(spacing: 4) {
                if vm.notchState == .open && Defaults[.settingsIconInNotch] {
                    Button(action: {
                        DispatchQueue.main.async {
                            SettingsWindowController.shared.showWindow()
                        }
                    }) {
                        Capsule()
                            .fill(.black)
                            .frame(width: 30 * notchScale, height: 30 * notchScale)
                            .overlay {
                                Image(systemName: "gear")
                                    .foregroundColor(.white)
                                    .padding()
                                    .imageScale(notchScale < 0.9 ? .small : .medium)
                            }
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .font(.system(.headline, design: .rounded))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)
        }
        .foregroundColor(.gray)
        .environmentObject(vm)
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
