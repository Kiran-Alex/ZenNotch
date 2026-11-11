//
//  Constants.swift
//  boringNotch
//
//  Created by Richard Kunkli on 2024. 10. 17..
//

import SwiftUI
import Defaults

private let availableDirectories = FileManager
    .default
    .urls(for: .documentDirectory, in: .userDomainMask)
let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
let bundleIdentifier = Bundle.main.bundleIdentifier!
let appVersion = "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))"

let temporaryDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
let spacing: CGFloat = 16

enum CalendarSelectionState: Codable, Defaults.Serializable {
    case all
    case selected(Set<String>)
}

/// Cards shown side by side in the open notch.
enum NotchCardKind: String, CaseIterable, Identifiable, Defaults.Serializable {
    case tasks, focus, notes, events

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tasks: return "Tasks"
        case .focus: return "Focus timer"
        case .notes: return "Notepad"
        case .events: return "Events"
        }
    }

    var icon: String {
        switch self {
        case .tasks: return "checklist"
        case .focus: return "timer"
        case .notes: return "square.and.pencil"
        case .events: return "calendar"
        }
    }

    /// Relative width when cards share the row (tasks needs the most room).
    var widthWeight: CGFloat {
        switch self {
        case .tasks: return 2.1
        case .focus: return 1.0
        case .notes: return 0.98
        case .events: return 1.0
        }
    }
}

enum HideNotchOption: String, Defaults.Serializable {
    case always
    // Kept so previously saved values still decode; now behaves like `.always`.
    case nowPlayingOnly
    case never
}

extension Defaults.Keys {
    // MARK: General
    static let menubarIcon = Key<Bool>("menubarIcon", default: true)
    static let showOnAllDisplays = Key<Bool>("showOnAllDisplays", default: false)
    static let automaticallySwitchDisplay = Key<Bool>("automaticallySwitchDisplay", default: true)
    static let releaseName = Key<String>("releaseName", default: "Flying Rabbit 🐇🪽")
    
    // MARK: Behavior
    static let minimumHoverDuration = Key<TimeInterval>("minimumHoverDuration", default: 0.3)
    static let enableHaptics = Key<Bool>("enableHaptics", default: true)
    static let openNotchOnHover = Key<Bool>("openNotchOnHover", default: true)
    static let extendHoverArea = Key<Bool>("extendHoverArea", default: false)
    static let notchHeightMode = Key<WindowHeightMode>(
        "notchHeightMode",
        default: WindowHeightMode.matchRealNotchSize
    )
    static let nonNotchHeightMode = Key<WindowHeightMode>(
        "nonNotchHeightMode",
        default: WindowHeightMode.matchMenuBar
    )
    static let nonNotchHeight = Key<CGFloat>("nonNotchHeight", default: 32)
    static let notchHeight = Key<CGFloat>("notchHeight", default: 32)
    //static let openLastTabByDefault = Key<Bool>("openLastTabByDefault", default: false)
    static let showOnLockScreen = Key<Bool>("showOnLockScreen", default: false)
    static let hideFromScreenRecording = Key<Bool>("hideFromScreenRecording", default: false)
    
    // MARK: Appearance
    static let showEmojis = Key<Bool>("showEmojis", default: false)
    //static let alwaysShowTabs = Key<Bool>("alwaysShowTabs", default: true)
    static let settingsIconInNotch = Key<Bool>("settingsIconInNotch", default: true)
    static let enableShadow = Key<Bool>("enableShadow", default: true)
    static let cornerRadiusScaling = Key<Bool>("cornerRadiusScaling", default: true)

    static let showNotHumanFace = Key<Bool>("showNotHumanFace", default: false)
    static let tileShowLabels = Key<Bool>("tileShowLabels", default: false)
    static let showCalendar = Key<Bool>("showCalendar", default: true)
    static let hideCompletedReminders = Key<Bool>("hideCompletedReminders", default: true)
    
    // MARK: Gestures
    static let enableGestures = Key<Bool>("enableGestures", default: true)
    static let gestureSensitivity = Key<CGFloat>("gestureSensitivity", default: 200.0)
    
    // MARK: Downloads
    static let enableDownloadListener = Key<Bool>("enableDownloadListener", default: true)
    static let enableSafariDownloads = Key<Bool>("enableSafariDownloads", default: true)
    static let selectedDownloadIndicatorStyle = Key<DownloadIndicatorStyle>("selectedDownloadIndicatorStyle", default: DownloadIndicatorStyle.progress)
    static let selectedDownloadIconStyle = Key<DownloadIconStyle>("selectedDownloadIconStyle", default: DownloadIconStyle.onlyAppIcon)
    
    // MARK: Notch cards
    /// Left-to-right order of the cards in the open notch (reordered by dragging a card's handle).
    static let cardOrder = Key<[NotchCardKind]>("cardOrder", default: NotchCardKind.allCases)
    /// Cards turned off in Settings > Appearance.
    static let hiddenCards = Key<[NotchCardKind]>("hiddenCards", default: [])

    // MARK: Focus timer
    /// Session length in minutes.
    static let focusDuration = Key<Int>("focusDuration", default: 45)
    /// Total focused seconds per reminder id (local only; Reminders can't store it).
    static let focusTotals = Key<[String: Int]>("focusTotals", default: [:])

    // MARK: Tasks
    /// Manual order of open tasks (reminder ids). Local only: EventKit has no API
    /// for a reminder's position, so this can't sync to the Reminders app.
    static let taskOrder = Key<[String]>("taskOrder", default: [])
    /// Planned focus length in minutes per reminder id ("Work for 45 mins").
    /// Local only: Reminders has no field for it.
    static let taskDurations = Key<[String: Int]>("taskDurations", default: [:])

    // MARK: Calendar
    static let calendarSelectionState = Key<CalendarSelectionState>("calendarSelectionState", default: .all)
    static let hideAllDayEvents = Key<Bool>("hideAllDayEvents", default: false)
    static let showFullEventTitles = Key<Bool>("showFullEventTitles", default: false)
    static let autoScrollToNextEvent = Key<Bool>("autoScrollToNextEvent", default: true)
    
    // MARK: Fullscreen Media Detection
    static let hideNotchOption = Key<HideNotchOption>("hideNotchOption", default: .always)
    
    // MARK: Advanced Settings
    static let useCustomAccentColor = Key<Bool>("useCustomAccentColor", default: false)
    static let customAccentColorData = Key<Data?>("customAccentColorData", default: nil)
    // Show or hide the title bar
    static let hideTitleBar = Key<Bool>("hideTitleBar", default: true)

    static let didClearLegacyURLCacheV1 = Key<Bool>("didClearLegacyURLCache_v1", default: false)
}
