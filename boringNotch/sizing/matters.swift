//
//  sizeMatters.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 05/08/24.
//

import Defaults
import Foundation
import SwiftUI

let downloadSneakSize: CGSize = .init(width: 65, height: 1)
let batterySneakSize: CGSize = .init(width: 160, height: 1)

let shadowPadding: CGFloat = 20
/// Open notch size at full scale (screens 1470pt wide or more, e.g. a default 13" Air).
let baseOpenNotchSize: CGSize = .init(width: 680, height: 345)
/// The window always fits the full-size notch; smaller screens draw a smaller notch inside it.
let windowSize: CGSize = .init(width: baseOpenNotchSize.width, height: baseOpenNotchSize.height + shadowPadding)

/// Screen width at which the notch is drawn at full size.
let notchReferenceScreenWidth: CGFloat = 1470

/// Scale for the open notch and everything in it (text, icons, spacing) on this
/// screen: narrower screens (or "Larger Text" display settings) get a smaller
/// notch, so it looks physically the same as on a default-scaled MacBook Air.
/// Never larger than full size, never below 80% (keeps text readable).
@MainActor func notchScale(screenUUID: String? = nil) -> CGFloat {
    let screen = screenUUID.flatMap { NSScreen.screen(withUUID: $0) } ?? NSScreen.main
    guard let width = screen?.frame.width, width > 0 else { return 1 }
    return min(1, max(0.8, width / notchReferenceScreenWidth))
}

@MainActor func getOpenNotchSize(screenUUID: String? = nil) -> CGSize {
    let scale = notchScale(screenUUID: screenUUID)
    return CGSize(width: (baseOpenNotchSize.width * scale).rounded(),
                  height: (baseOpenNotchSize.height * scale).rounded())
}
let cornerRadiusInsets: (opened: (top: CGFloat, bottom: CGFloat), closed: (top: CGFloat, bottom: CGFloat)) = (opened: (top: 19, bottom: 24), closed: (top: 6, bottom: 14))

enum MusicPlayerImageSizes {
    static let cornerRadiusInset: (opened: CGFloat, closed: CGFloat) = (opened: 13.0, closed: 4.0)
    static let size = (opened: CGSize(width: 90, height: 90), closed: CGSize(width: 20, height: 20))
}

@MainActor func getScreenFrame(_ screenUUID: String? = nil) -> CGRect? {
    var selectedScreen = NSScreen.main

    if let uuid = screenUUID {
        selectedScreen = NSScreen.screen(withUUID: uuid)
    }
    
    if let screen = selectedScreen {
        return screen.frame
    }
    
    return nil
}

@MainActor func getClosedNotchSize(screenUUID: String? = nil) -> CGSize {
    // Default notch size, to avoid using optionals
    var notchHeight: CGFloat = Defaults[.nonNotchHeight]
    var notchWidth: CGFloat = 185

    var selectedScreen = NSScreen.main

    if let uuid = screenUUID {
        selectedScreen = NSScreen.screen(withUUID: uuid)
    }

    // Check if the screen is available
    if let screen = selectedScreen {
        // Calculate and set the exact width of the notch
        if let topLeftNotchpadding: CGFloat = screen.auxiliaryTopLeftArea?.width,
           let topRightNotchpadding: CGFloat = screen.auxiliaryTopRightArea?.width
        {
            notchWidth = screen.frame.width - topLeftNotchpadding - topRightNotchpadding + 4
        }

        // Check if the Mac has a notch
        if screen.safeAreaInsets.top > 0 {
            // This is a display WITH a notch - use notch height settings
            notchHeight = Defaults[.notchHeight]
            if Defaults[.notchHeightMode] == .matchRealNotchSize {
                notchHeight = screen.safeAreaInsets.top
            } else if Defaults[.notchHeightMode] == .matchMenuBar {
                notchHeight = screen.frame.maxY - screen.visibleFrame.maxY
            }
        } else {
            // This is a display WITHOUT a notch - use non-notch height settings
            notchHeight = Defaults[.nonNotchHeight]
            if Defaults[.nonNotchHeightMode] == .matchMenuBar {
                notchHeight = screen.frame.maxY - screen.visibleFrame.maxY
            }
        }
    }

    return .init(width: notchWidth, height: notchHeight)
}
