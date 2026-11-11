//
//  NotepadView.swift
//  ZenNotch
//
//  Notepad card: a note per day with ‹ › to browse days and a word count.
//

import AppKit
import SwiftUI

struct NotepadView: View {
    @Environment(\.notchScale) var notchScale
    /// Card size value scaled for the notch's design proportions and this screen.
    private func cs(_ value: CGFloat) -> CGFloat { value * cardUIScale * notchScale }
    @ObservedObject private var notes = NotesManager.shared
    @State private var hostWindow: NSWindow?
    @State private var isEditing = false
    @FocusState private var editorFocused: Bool

    private static let focusOwner = "notes"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: cs(6)) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: cs(CardType.titleIcon), weight: .semibold))
                Text("Notepad")
                    .font(.system(size: cs(CardType.title), weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.top, cs(15))

            ViewThatFits(in: .horizontal) {
                HStack(spacing: cs(2)) {
                    Button {
                        notes.goToToday()
                    } label: {
                        Text(dateLabel)
                            .font(.system(size: cs(12), weight: .medium))
                            .foregroundStyle(PaperPalette.inkSecondary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("Go to today")
                    Spacer(minLength: cs(4))
                    dayButtons
                }
                // Not enough room: day arrows go under the date.
                VStack(alignment: .leading, spacing: cs(2)) {
                    Button {
                        notes.goToToday()
                    } label: {
                        Text(dateLabel)
                            .font(.system(size: cs(12), weight: .medium))
                            .foregroundStyle(PaperPalette.inkSecondary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("Go to today")
                    dayButtons
                }
            }
            .padding(.top, cs(6))

            StitchLine()
                .padding(.top, cs(8))
                .padding(.bottom, cs(6))

            editor

            HStack(spacing: cs(4)) {
                Image(systemName: "text.alignleft")
                Text(notes.wordCount == 1 ? "1 word" : "\(notes.wordCount) words")
                    .monospacedDigit()
            }
            .font(.system(size: cs(11.5)))
            .foregroundStyle(PaperPalette.inkSecondary)
            .padding(.top, cs(6))
            .padding(.bottom, cs(12))
        }
        .padding(.horizontal, cs(12))
        .background(WindowReaderView { hostWindow = $0 })
        .onChange(of: editorFocused) { _, focused in
            if !focused { endEditing() }
        }
        // Clicking into another app takes the keyboard away; stop editing then.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            guard isEditing, let window = note.object as? NSWindow, window === hostWindow else { return }
            editorFocused = false
            endEditing()
        }
        .onDisappear {
            endEditing()
            notes.flush()
        }
    }

    private var dateLabel: String {
        notes.selectedDate.formatted(.dateTime.day().month(.abbreviated).year())
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if notes.text.isEmpty {
                Text("Jot something down…")
                    .font(.system(size: cs(CardType.body)))
                    .foregroundStyle(PaperPalette.inkSecondary)
                    .padding(.top, cs(1))
                    .allowsHitTesting(false)
            }
            TextEditor(text: Binding(get: { notes.text }, set: { notes.text = $0 }))
                .font(.system(size: cs(CardType.body)))
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .tint(PaperPalette.ink)
                .focused($editorFocused)
                // Line up the editor's text with the placeholder.
                .padding(.leading, cs(-5))
                .accessibilityLabel("Note for \(dateLabel)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            // The notch can't take the keyboard until asked; the first click does that.
            if !isEditing {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { startEditing() }
            }
        }
    }

    private var dayButtons: some View {
        HStack(spacing: cs(2)) {
            dayButton("chevron.left", label: "Previous day") { notes.shiftDay(by: -1) }
            dayButton("chevron.right", label: "Next day") { notes.shiftDay(by: 1) }
        }
    }

    private func dayButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: cs(11), weight: .bold))
                .frame(width: cs(17), height: cs(17))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func startEditing() {
        (hostWindow as? BoringNotchSkyLightWindow)?.beginKeyboardFocus(owner: Self.focusOwner)
        isEditing = true
        DispatchQueue.main.async { editorFocused = true }
        // If focus never arrives, don't leave the notch holding the keyboard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if !editorFocused { endEditing() }
        }
    }

    private func endEditing() {
        guard isEditing else { return }
        isEditing = false
        notes.flush()
        (hostWindow as? BoringNotchSkyLightWindow)?.endKeyboardFocus(owner: Self.focusOwner)
    }
}

/// Exposes the hosting NSWindow (reports only when the view moves into a window).
struct WindowReaderView: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ResolvingView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ResolvingView: NSView {
        var onResolve: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = self.window
            DispatchQueue.main.async { [onResolve] in onResolve?(window) }
        }
    }
}
