//
//  OnboardingView.swift
//  boringNotch
//
//  Created by Alexander on 2025-06-23.
//

import LaunchAtLogin
import SwiftUI

enum OnboardingStep {
    case welcome
    case calendarPermission
    case remindersPermission
    case launchAtLogin
    case finished
}

private let calendarService = CalendarService()

struct OnboardingView: View {
    @State var step: OnboardingStep = .welcome
    let onFinish: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        ZStack {
            switch step {
            case .welcome:
                WelcomeView {
                    withAnimation(.easeInOut(duration: 0.6)) {
                        step = .calendarPermission
                    }
                }
                .transition(.opacity)

            case .calendarPermission:
                PermissionRequestView(
                    icon: Image(systemName: "calendar"),
                    title: "Enable Calendar Access",
                    description: "ZenNotch can show all your upcoming events in one place. Access to your calendar is needed to display your schedule.",
                    privacyNote: "Your calendar data is only used to show your events and is never shared.",
                    onAllow: {
                        Task {
                            await requestCalendarPermission()
                            withAnimation(.easeInOut(duration: 0.6)) {
                                step = .remindersPermission
                            }
                        }
                    },
                    onSkip: {
                        withAnimation(.easeInOut(duration: 0.6)) {
                            step = .remindersPermission
                        }
                    }
                )
                .transition(.opacity)

            case .remindersPermission:
                PermissionRequestView(
                    icon: Image(systemName: "checklist"),
                    title: "Enable Reminders Access",
                    description: "ZenNotch can show your scheduled reminders alongside your calendar events. Access to Reminders is needed to display your reminders.",
                    privacyNote: "Your reminders data is only used to show your reminders and is never shared.",
                    onAllow: {
                        Task {
                            await requestRemindersPermission()
                            withAnimation(.easeInOut(duration: 0.6)) {
                                step = .launchAtLogin
                            }
                        }
                    },
                    onSkip: {
                        withAnimation(.easeInOut(duration: 0.6)) {
                            step = .launchAtLogin
                        }
                    }
                )
                .transition(.opacity)
            case .launchAtLogin:
                PermissionRequestView(
                    icon: Image(systemName: "power"),
                    title: "Open at Login",
                    description: "ZenNotch can start by itself when you log in, so your notch is there after every restart. You can change this any time in Settings.",
                    privacyNote: nil,
                    allowTitle: "Open at Login",
                    skipTitle: "Not Now",
                    onAllow: {
                        LaunchAtLogin.isEnabled = true
                        finishPermissions()
                    },
                    onSkip: {
                        finishPermissions()
                    }
                )
                .transition(.opacity)

            case .finished:
                OnboardingFinishView(onFinish: onFinish, onOpenSettings: onOpenSettings)
            }
        }
        .frame(width: 400, height: 600)
    }

    /// Last permission step done: mark onboarding complete so the notch becomes interactive.
    private func finishPermissions() {
        withAnimation(.easeInOut(duration: 0.6)) {
            BoringViewCoordinator.shared.firstLaunch = false
            step = .finished
        }
    }

    // MARK: - Permission Request Logic

    /// System permission dialogs take focus from this agent app (no Dock icon),
    /// which leaves the onboarding window buried. Bring it back after each one.
    @MainActor
    private func bringOnboardingToFront() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier == NSUserInterfaceItemIdentifier("OnboardingWindow") }) {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    func requestCalendarPermission() async {
        _ = try? await calendarService.requestAccess(to: .event)
        await bringOnboardingToFront()
    }

    func requestRemindersPermission() async {
        _ = try? await calendarService.requestAccess(to: .reminder)
        await bringOnboardingToFront()
    }
}
