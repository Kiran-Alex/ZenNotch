//
//  NotesManager.swift
//  ZenNotch
//
//  One note per day, stored locally as JSON in the app's Application Support
//  folder (Apple Notes has no API for other apps). Saves shortly after typing.
//

import Foundation
import SwiftUI

@MainActor
final class NotesManager: ObservableObject {
    static let shared = NotesManager()

    @Published var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @Published private var notes: [String: String] = [:]
    /// Month calendar for jumping to a day. The notch draws it over the whole row,
    /// since the notepad card alone is too narrow for a month.
    @Published var isPickerOpen = false
    @Published var pickerMonth = Date()

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?
    private var dayChangeObserver: NSObjectProtocol?

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ZenNotch", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("notes.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            notes = decoded
        }
        // Roll over to the new day's note at midnight.
        dayChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.selectedDate = Calendar.current.startOfDay(for: Date()) }
        }
    }

    private var key: String { Self.keyFormatter.string(from: selectedDate) }

    var text: String {
        get { notes[key] ?? "" }
        set {
            notes[key] = newValue.isEmpty ? nil : newValue
            scheduleSave()
        }
    }

    var wordCount: Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    var isToday: Bool { Calendar.current.isDateInToday(selectedDate) }

    func shiftDay(by days: Int) {
        flush()
        if let next = Calendar.current.date(byAdding: .day, value: days, to: selectedDate) {
            selectedDate = Calendar.current.startOfDay(for: next)
        }
    }

    /// Days that have a note (start of day), for the dots in the date picker.
    var daysWithNotes: Set<Date> {
        Set(notes.compactMap { key, text in
            text.isEmpty ? nil : Self.keyFormatter.date(from: key).map { Calendar.current.startOfDay(for: $0) }
        })
    }

    func go(to day: Date) {
        flush()
        selectedDate = Calendar.current.startOfDay(for: day)
    }

    func goToToday() {
        flush()
        selectedDate = Calendar.current.startOfDay(for: Date())
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
        do {
            let data = try JSONEncoder().encode(notes)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("NotesManager: failed to save notes: \(error.localizedDescription)")
        }
    }
}
