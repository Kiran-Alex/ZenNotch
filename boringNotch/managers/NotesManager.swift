//
//  NotesManager.swift
//  ZenNotch
//
//  The sticky note: one note that stays put (no days), stored locally as a text
//  file in the app's Application Support folder. Saves shortly after typing.
//  The old per-day notes.json is left untouched on disk.
//

import Foundation
import SwiftUI

@MainActor
final class NotesManager: ObservableObject {
    static let shared = NotesManager()

    @Published var text: String = "" {
        didSet { if text != oldValue { scheduleSave() } }
    }

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ZenNotch", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("sticky.txt")
        if let saved = try? String(contentsOf: fileURL, encoding: .utf8) {
            // Assigned in init, so didSet doesn't fire and nothing is re-saved.
            text = saved
        }
    }

    var wordCount: Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    /// Writes pending changes right away (e.g. when the notch closes).
    func flush() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        write()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            saveTask = nil
            write()
        }
    }

    private func write() {
        #if DEBUG
        if DebugMock.active { return }
        #endif
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("NotesManager: failed to save sticky note: \(error.localizedDescription)")
        }
    }
}
