//
//  Color+AccentColor.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-24.
//

import SwiftUI

/// The settings and onboarding screens follow the macOS system accent colour.
extension Color {
    static var effectiveAccent: Color { .accentColor }

    /// A softer version of the accent colour, for backgrounds.
    static var effectiveAccentBackground: Color { Color.effectiveAccent.opacity(0.25) }
}

extension NSColor {
    static var effectiveAccent: NSColor { NSColor.controlAccentColor }

    /// A softer version of the accent colour as NSColor, for backgrounds.
    static var effectiveAccentBackground: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.25) }
}
