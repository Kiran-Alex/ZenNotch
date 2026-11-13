//
//  WelcomeView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 2024. 09. 26..
//

import SwiftUI

/// Slow rings spreading out from the logo, like water around a pebble.
private struct RippleRings: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let rings = 4
    private let period: Double = 9

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let t = reduceMotion ? 0.35 : timeline.date.timeIntervalSinceReferenceDate / period
                for i in 0..<rings {
                    let phase = (t + Double(i) / Double(rings)).truncatingRemainder(dividingBy: 1)
                    let radius = 58 + phase * 230
                    // Fade in quickly, then drift away.
                    let alpha = 0.22 * sin(min(phase * 6, 1) * .pi / 2) * (1 - phase)
                    let rect = CGRect(x: center.x - radius, y: center.y - radius * 0.62,
                                      width: radius * 2, height: radius * 1.24)
                    context.stroke(Path(ellipseIn: rect),
                                   with: .color(PaperPalette.ink.opacity(alpha)),
                                   lineWidth: 1.2)
                }
            }
        }
        .frame(width: 520, height: 320)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct WelcomeView: View {
    var onGetStarted: (() -> Void)? = nil

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 8) {
                Image("zenlogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 120, height: 120)
                    .shadow(color: .black.opacity(0.22), radius: 10, y: 8)
                    .background { RippleRings().offset(y: 14) }
                    .padding(.bottom, 14)
                Text("ZenNotch")
                    .font(.system(.largeTitle, design: .default))
                    .fontWeight(.semibold)
                    .foregroundStyle(PaperPalette.ink)
                Text("Welcome")
                    .font(.title)
                    .foregroundStyle(PaperPalette.inkSecondary)
                    .padding(.bottom, 30)
                Button {
                    onGetStarted?()
                } label: {
                    Text("Get started")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 6)
                }
                .buttonStyle(BorderedProminentButtonStyle())
                .tint(PaperPalette.ink)
            }
            .padding(.top)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text("Made with ❤️ by Kiran Alex")
                .font(.caption)
                .foregroundStyle(PaperPalette.inkSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding()
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .background {
            LinearGradient(
                colors: [Color(red: 0.74, green: 0.71, blue: 0.84), PaperPalette.lavender, Color(red: 0.58, green: 0.54, blue: 0.72)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .environment(\.colorScheme, .light)
    }
}

#Preview {
    WelcomeView()
}
