//
//  NotchCardsView.swift
//  ZenNotch
//
//  The open notch's main page: paper cards side by side (tasks, focus timer,
//  sticky note, events). Cards share the notch's width by weight, can be turned
//  off in Settings > Appearance, and are reordered by dragging the small
//  handle at the top of each card.
//

import Defaults
import SwiftUI

extension NotchCardKind {
    var tint: Color {
        switch self {
        case .tasks: return PaperPalette.sage
        case .focus: return PaperPalette.lavender
        case .notes: return PaperPalette.sticky
        case .events: return PaperPalette.slate
        }
    }
}

struct NotchCardsView: View {
    @EnvironmentObject var vm: BoringViewModel
    @Default(.cardOrder) private var order
    @Default(.hiddenCards) private var hidden

    /// Card being dragged by its handle, the pointer's x in the row, and where on
    /// the card it was grabbed (so the card doesn't jump under the pointer).
    @State private var draggingCard: NotchCardKind?
    @State private var dragPointerX: CGFloat = 0
    @State private var grabDelta: CGFloat = 0
    @State private var cardMids: [NotchCardKind: CGFloat] = [:]
    @GestureState private var isHandleDragActive = false

    @Environment(\.notchScale) private var notchScale
    private var gap: CGFloat { 7 * notchScale }
    private static let rowSpace = "notchCardsRow"

    /// Saved order, plus any card kinds added in a later version.
    private var visibleCards: [NotchCardKind] {
        let known = order + NotchCardKind.allCases.filter { !order.contains($0) }
        return known.filter { !hidden.contains($0) }
    }

    var body: some View {
        GeometryReader { geo in
            let cards = visibleCards
            let totalWeight = cards.reduce(0) { $0 + $1.widthWeight }
            let usable = max(0, geo.size.width - gap * CGFloat(max(cards.count - 1, 0)))

            HStack(spacing: gap) {
                ForEach(cards) { kind in
                    card(kind)
                        .frame(width: totalWeight > 0 ? usable * kind.widthWeight / totalWeight : 0)
                        .scaleEffect(draggingCard == kind ? 1.02 : 1)
                        .shadow(color: .black.opacity(draggingCard == kind ? 0.35 : 0), radius: 12, y: 4)
                        .offset(x: offset(for: kind))
                        .zIndex(draggingCard == kind ? 1 : 0)
                        // The dragged card tracks the pointer exactly; neighbours animate.
                        .transaction { if draggingCard == kind { $0.animation = nil } }
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(
                                    key: CardMidKey.self,
                                    value: [kind: g.frame(in: .named(Self.rowSpace)).midX]
                                )
                            }
                        )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .coordinateSpace(name: Self.rowSpace)
            .onPreferenceChange(CardMidKey.self) { cardMids = $0 }
        }
        .onChange(of: isHandleDragActive) { _, active in
            if !active && draggingCard != nil { endDrag() }
        }
        .onChange(of: draggingCard) { vm.setKeepOpen("cardDrag", draggingCard != nil) }
        .onDisappear {
            vm.setKeepOpen("cardDrag", false)
        }
    }

    @ViewBuilder
    private func card(_ kind: NotchCardKind) -> some View {
        Group {
            switch kind {
            case .tasks: TasksView()
            case .focus: FocusTimerView()
            case .notes: NotepadView()
            case .events: EventsCardView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(PaperPalette.ink)
        .background(PaperBackground(tint: kind.tint, cornerRadius: 14 * notchScale))
        // Light controls (menus, caret, text) on the light paper.
        .environment(\.colorScheme, .light)
        .overlay(alignment: .top) { handle(kind) }
        .environmentObject(vm)
    }

    // MARK: Handle + reorder

    private func handle(_ kind: NotchCardKind) -> some View {
        Capsule()
            .fill(PaperPalette.ink.opacity(draggingCard == kind ? 0.45 : 0.22))
            .frame(width: 22 * notchScale, height: 3.5 * notchScale)
            .padding(.horizontal, 16 * notchScale)
            .padding(.vertical, 4 * notchScale)
            .contentShape(Rectangle())
            .gesture(handleGesture(kind))
            .help("Drag to move this card")
            .accessibilityElement()
            .accessibilityLabel("\(kind.title) card")
            .accessibilityAction(named: "Move left") { step(kind, -1) }
            .accessibilityAction(named: "Move right") { step(kind, 1) }
    }

    private func offset(for kind: NotchCardKind) -> CGFloat {
        guard draggingCard == kind, let mid = cardMids[kind] else { return 0 }
        return dragPointerX - mid
    }

    private func handleGesture(_ kind: NotchCardKind) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.rowSpace))
            .updating($isHandleDragActive) { _, active, _ in active = true }
            .onChanged { value in
                if draggingCard == nil {
                    guard let mid = cardMids[kind] else { return }
                    grabDelta = value.startLocation.x - mid
                    withAnimation(.smooth(duration: 0.15)) { draggingCard = kind }
                    haptic()
                }
                guard draggingCard == kind else { return }
                dragPointerX = value.location.x - grabDelta
                swapIfNeeded(kind)
            }
            .onEnded { _ in endDrag() }
    }

    /// Swaps with a neighbour once the dragged card's centre passes the neighbour's centre.
    private func swapIfNeeded(_ kind: NotchCardKind) {
        let cards = visibleCards
        guard let i = cards.firstIndex(of: kind) else { return }
        if i > 0, let prev = cardMids[cards[i - 1]], dragPointerX < prev {
            move(kind, to: i - 1)
        } else if i < cards.count - 1, let next = cardMids[cards[i + 1]], dragPointerX > next {
            move(kind, to: i + 1)
        }
    }

    private func step(_ kind: NotchCardKind, _ delta: Int) {
        guard let i = visibleCards.firstIndex(of: kind) else { return }
        move(kind, to: i + delta)
    }

    private func move(_ kind: NotchCardKind, to newIndex: Int) {
        var cards = visibleCards
        guard let from = cards.firstIndex(of: kind), cards.indices.contains(newIndex), from != newIndex else { return }
        cards.remove(at: from)
        cards.insert(kind, at: newIndex)
        withAnimation(.smooth(duration: 0.22)) {
            // Hidden cards keep their place at the end, so turning them back on is predictable.
            order = cards + NotchCardKind.allCases.filter { !cards.contains($0) }
        }
        haptic()
    }

    private func endDrag() {
        guard draggingCard != nil else { return }
        withAnimation(.smooth(duration: 0.22)) {
            draggingCard = nil
            dragPointerX = 0
        }
    }

    private func haptic() {
        if Defaults[.enableHaptics] {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }
}

private struct CardMidKey: PreferenceKey {
    static let defaultValue: [NotchCardKind: CGFloat] = [:]
    static func reduce(value: inout [NotchCardKind: CGFloat], nextValue: () -> [NotchCardKind: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}
