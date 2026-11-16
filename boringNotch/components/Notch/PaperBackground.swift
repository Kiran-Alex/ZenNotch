//
//  PaperBackground.swift
//  ZenNotch
//
//  Procedural paper texture: a tinted base, soft light falloff, fine grain and
//  sparse fibres. Generated once in code (no image assets), tiles at any size.
//

import AppKit
import SwiftUI

/// Overall type and spacing scale for the notch cards (the per-screen notch
/// scale is applied on top of this).
let cardUIScale: CGFloat = 1.0

/// Per-screen scale of the open notch (see `notchScale(screenUUID:)`), set once
/// at the top of the notch so every card and icon follows it.
private struct NotchScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var notchScale: CGFloat {
        get { self[NotchScaleKey.self] }
        set { self[NotchScaleKey.self] = newValue }
    }
}

/// Shared header sizes so every card's title matches ("Today's tasks", "Sticky", "Events").
enum CardType {
    static let title: CGFloat = 14
    static let titleIcon: CGFloat = 11.5
    /// Main text in every card: task titles, note text, event titles.
    static let body: CGFloat = 12.5
    /// Small labels: tasks' To do / Completed tabs, Events' REMINDERS heading.
    static let label: CGFloat = 10.5
}

enum PaperPalette {
    /// Card colours from the design reference.
    static let sage = Color(red: 0.553, green: 0.690, blue: 0.592)      // tasks
    static let lavender = Color(red: 0.635, green: 0.596, blue: 0.776)  // focus timer
    static let sticky = Color(red: 0.718, green: 0.675, blue: 0.369)    // sticky note
    static let slate = Color(red: 0.580, green: 0.667, blue: 0.761)     // events
    static let ink = Color(red: 0.11, green: 0.16, blue: 0.13)
    static let inkSecondary = Color(red: 0.11, green: 0.16, blue: 0.13).opacity(0.62)
    static let divider = Color.black.opacity(0.18)
}

struct PaperBackground: View {
    var tint: Color = PaperPalette.sage
    var cornerRadius: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(tint)
            .overlay {
                // Gentle top-left light so the sheet doesn't look flat.
                LinearGradient(
                    colors: [.white.opacity(0.10), .clear, .black.opacity(0.06)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
            .overlay {
                Image(nsImage: PaperTexture.grain)
                    .resizable(resizingMode: .tile)
                    .blendMode(.overlay)
                    .opacity(0.55)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}

private enum PaperTexture {
    /// 192×192 seamless tile. Mid-grey is neutral under `.overlay`, so lighter and
    /// darker specks brighten/darken the tint without shifting its hue.
    static let grain: NSImage = {
        let size = 192
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32),
            let data = rep.bitmapData
        else { return NSImage(size: NSSize(width: 1, height: 1)) }

        var rng = SeededGenerator(seed: 0x5EED_FACE)
        for i in 0..<(size * size) {
            // Fine grain around neutral grey.
            var value = 128 + Int.random(in: -22...22, using: &rng)
            // Sparse darker fibres and lighter flecks.
            let roll = Int.random(in: 0..<1000, using: &rng)
            if roll < 6 { value -= 55 } else if roll < 10 { value += 45 }
            let byte = UInt8(clamping: value)
            let p = i * 4
            data[p] = byte; data[p + 1] = byte; data[p + 2] = byte; data[p + 3] = 255
        }
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        return image
    }()
}

/// Deterministic RNG so the texture looks identical on every launch.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
