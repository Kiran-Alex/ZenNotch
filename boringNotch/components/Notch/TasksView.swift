//
//  TasksView.swift
//  ZenNotch
//
//  "Today's tasks" panel on a paper card, backed by Apple Reminders.
//  Responsive: a tall notch gets the full layout (stacked header, two-line rows);
//  a short notch gets a compact layout (single header row, one-line rows).
//

import AppKit
import Defaults
import SwiftUI

struct TasksView: View {
    @Environment(\.notchScale) var notchScale
    /// Card size value scaled for the notch's design proportions and this screen.
    private func cs(_ value: CGFloat) -> CGFloat { value * cardUIScale * notchScale }
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var tasks = TasksManager.shared
    @ObservedObject private var focus = FocusTimerManager.shared
    @Default(.hiddenCards) private var hiddenCards

    enum Tab { case todo, completed }

    @State private var tab: Tab = .todo
    @State private var newTitle = ""
    @State private var isAdding = false
    @State private var editingID: String?
    @State private var editingTitle = ""
    @State private var hostWindow: NSWindow?
    @FocusState private var focusedField: Field?
    @State private var rowPositions: [RowPosition] = []
    /// Row to glow briefly after it's added.
    @State private var highlightedID: String?
    /// "Added to <list>" message shown in the add bar for a moment.
    @State private var addedMessage: String?
    /// Detected-date text the user dismissed with ×, so it's saved as plain title.
    @State private var dismissedDateText: String?
    /// Detected text whose time the user removed (keeps the date, drops the time).
    @State private var dismissedTimeText: String?
    /// Detected duration text the user dismissed with × ("for 45 mins" stays in the title).
    @State private var dismissedDurationText: String?
    /// Detected priority / list-tag text the user dismissed with ×.
    @State private var dismissedPriorityText: String?
    @State private var dismissedListText: String?
    @State private var showMonthPicker = false
    /// Task whose due date is being picked from the calendar ("Custom date…").
    @State private var dueDateTarget: TaskItem?
    /// Drag-to-reorder: the row being dragged, the pointer's y in the list viewport,
    /// and where in the row it was grabbed (so the row doesn't jump to the pointer).
    @State private var draggingID: String?
    @State private var dragPointerY: CGFloat = 0
    @State private var grabDelta: CGFloat = 0
    @State private var lastEdgeStep = Date.distantPast
    /// Resets if the system cancels the drag without calling onEnded.
    @GestureState private var isDragGestureActive = false
    @State private var pickerMonth = Date()
    /// Narrow card (shares the notch with other cards): tighter header and rows.
    @State private var isNarrow = false

    enum Field: Hashable { case add, edit(String) }

    /// Below this card height we switch to the compact layout.
    private let compactHeightThreshold: CGFloat = 150
    /// Below this card width the header and rows get tighter.
    private let narrowWidthThreshold: CGFloat = 200
    private static let focusOwner = "tasks"

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < compactHeightThreshold * notchScale
            VStack(alignment: .leading, spacing: 0) {
                if compact {
                    HStack(spacing: cs(12)) {
                        title(compact: true)
                        tabPicker
                        Spacer(minLength: cs(8))
                        dateNavigator
                    }
                    .padding(.horizontal, cs(14))
                    .padding(.top, cs(14))
                    .padding(.bottom, cs(4))
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            title(compact: false).fixedSize()
                            Spacer(minLength: cs(6))
                            dateNavigator.fixedSize()
                        }
                        // Not enough room: date controls go under the title (nothing is cut off).
                        VStack(alignment: .leading, spacing: cs(4)) {
                            title(compact: false)
                            dateNavigator.fixedSize()
                        }
                    }
                    .padding(.horizontal, cs(isNarrow ? 12 : 16))
                    .padding(.top, cs(13))
                    tabPicker
                        .padding(.horizontal, cs(isNarrow ? 12 : 16))
                        .padding(.top, cs(6))
                        .padding(.bottom, cs(2))
                }

                content(compact: compact)

                if tasks.hasAccess && tab == .todo {
                    // Stitched seam separating the list from the input bar.
                    StitchLine()
                        .padding(.horizontal, cs(compact ? 14 : (isNarrow ? 12 : 18)))
                        .padding(.top, cs(compact ? 3 : 4))
                        .padding(.bottom, cs(compact ? 5 : 7))
                    addBar(compact: compact)
                        .padding(.horizontal, cs(compact ? 10 : 12))
                        .padding(.bottom, cs(compact ? 7 : 9))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .onAppear { isNarrow = geo.size.width < narrowWidthThreshold * notchScale }
            .onChange(of: geo.size.width) { _, width in isNarrow = width < narrowWidthThreshold * notchScale }
            .overlay(alignment: .topTrailing) {
                if showMonthPicker || dueDateTarget != nil {
                    ZStack(alignment: .topTrailing) {
                        // Click anywhere else on the card to dismiss.
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { closeMonthPicker() }
                        if let target = dueDateTarget {
                            // Picking a due date for one task.
                            MonthPicker(
                                month: $pickerMonth,
                                selected: target.dueDay,
                                daysWithTasks: tasks.daysWithTasks,
                                cell: pickerCell(cardHeight: geo.size.height, cardWidth: geo.size.width, compact: compact, hasTitle: true),
                                title: "Due date · \(target.title)",
                                onPick: { day in
                                    tasks.setDueDay(target, day)
                                    closeMonthPicker()
                                },
                                onToday: {
                                    tasks.setDueDay(target, Date())
                                    closeMonthPicker()
                                }
                            )
                            .padding(.top, cs(compact ? 4 : 42))
                            .padding(.trailing, cs(10))
                            .transition(.scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity))
                        } else {
                        MonthPicker(
                            month: $pickerMonth,
                            selected: tasks.selectedDate,
                            daysWithTasks: tasks.daysWithTasks,
                            cell: pickerCell(cardHeight: geo.size.height, cardWidth: geo.size.width, compact: compact, hasTitle: false),
                            onPick: { day in
                                tasks.go(to: day)
                                closeMonthPicker()
                            },
                            onToday: {
                                tasks.goToToday()
                                closeMonthPicker()
                            }
                        )
                        .padding(.top, cs(compact ? 4 : 42))
                        .padding(.trailing, cs(10))
                        .transition(.scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity))
                        }
                    }
                }
            }
        }
        .foregroundStyle(PaperPalette.ink)
        .background(
            Color.clear
                .contentShape(Rectangle())
                // Clicking empty paper while renaming saves the name.
                .onTapGesture { if editingID != nil { finishEditing(save: true) } }
        )
        // Light controls (menus, caret, text) on the light paper.
        .environment(\.colorScheme, .light)
        .background(WindowReader { hostWindow = $0 })
        .onAppear { tasks.reload() }
        .onDisappear {
            endTyping()
            vm.setKeepOpen("tasks", false)
        }
        .onChange(of: focusedField) { _, newValue in
            if newValue == nil { endTyping() }
        }
        .onChange(of: newTitle) { syncKeepOpen() }
        .onChange(of: editingID) { syncKeepOpen() }
        .onChange(of: isAdding) { syncKeepOpen() }
        .onChange(of: draggingID) { syncKeepOpen() }
        .onChange(of: isDragGestureActive) { _, active in
            if !active && draggingID != nil { endDrag() }
        }
        // Clicking into another app takes keyboard focus away from the notch, but the
        // text field still thinks it's focused. Treat that as "done typing" so the
        // notch can collapse again.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            guard isTyping, let window = note.object as? NSWindow, window === hostWindow else { return }
            focusedField = nil
            endTyping()
        }
    }

    // MARK: Header

    @ViewBuilder
    private func title(compact: Bool) -> some View {
        let text = Text(headerTitle)
            .font(.system(size: cs(compact || isNarrow ? 14.5 : 15.5), weight: .semibold))
            .lineLimit(1)
        // Shrink a little rather than push the date controls off the card.
        text.minimumScaleFactor(0.75).layoutPriority(1)
    }

    private var headerTitle: String {
        let cal = Calendar.current
        if cal.isDateInToday(tasks.selectedDate) { return "Today's tasks" }
        if cal.isDateInTomorrow(tasks.selectedDate) { return "Tomorrow's tasks" }
        if cal.isDateInYesterday(tasks.selectedDate) { return "Yesterday's tasks" }
        return tasks.selectedDate.formatted(.dateTime.weekday(.wide)) + "'s tasks"
    }

    private var dateNavigator: some View {
        HStack(spacing: cs(4)) {
            iconButton("chevron.left", label: "Previous day") { tasks.shiftDay(by: -1) }
            Button {
                if showMonthPicker || dueDateTarget != nil {
                    closeMonthPicker()
                } else {
                    pickerMonth = tasks.selectedDate
                    withAnimation(.smooth(duration: 0.2)) { showMonthPicker = true }
                }
            } label: {
                HStack(spacing: cs(5)) {
                    Image(systemName: "calendar")
                    Text(tasks.selectedDate.formatted(.dateTime.day().month(.abbreviated)))
                }
                .font(.system(size: cs(12), weight: .medium))
                .padding(.horizontal, cs(8))
                .padding(.vertical, cs(4))
                .background(Color.black.opacity(showMonthPicker ? 0.13 : 0.07),
                            in: RoundedRectangle(cornerRadius: cs(7), style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Pick a day")
            .accessibilityLabel("Selected day \(tasks.selectedDate.formatted(date: .complete, time: .omitted)). Pick a day")
            iconButton("chevron.right", label: "Next day") { tasks.shiftDay(by: 1) }
        }
    }

    private var tabPicker: some View {
        HStack(spacing: cs(2)) {
            tabChip("To do", count: tasks.todo.count, value: .todo)
            tabChip("Completed", count: tasks.completed.count, value: .completed)
        }
        .padding(cs(3))
        .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: cs(9), style: .continuous))
        .fixedSize()
    }

    private func tabChip(_ label: String, count: Int, value: Tab) -> some View {
        let selected = tab == value
        return Button {
            withAnimation(.smooth(duration: 0.2)) { tab = value }
        } label: {
            HStack(spacing: cs(5)) {
                Text(label).fontWeight(selected ? .semibold : .regular)
                Text("\(count)")
                    .foregroundStyle(PaperPalette.inkSecondary)
                    .monospacedDigit()
            }
            .font(.system(size: cs(12)))
            .padding(.horizontal, cs(10))
            .padding(.vertical, cs(4))
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: cs(7), style: .continuous)
                        .fill(Color.white.opacity(0.35))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Content

    @ViewBuilder
    private func content(compact: Bool) -> some View {
        if !tasks.hasAccess {
            accessPrompt
        } else {
            let items = tab == .todo ? tasks.todo : tasks.completed
            if items.isEmpty {
                Text(tab == .todo ? "Nothing due. Add a task below." : "No tasks completed on this day.")
                    .font(.system(size: cs(13)))
                    .foregroundStyle(PaperPalette.inkSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                taskList(items, compact: compact)
                    .onHover { vm.isHoveringCalendar = $0 } // lets the list scroll without swipe-closing
            }
        }
    }

    /// Scrolling list whose top/bottom edge fades while tasks are cut off there.
    /// Rows report their position in the viewport, used for the fades and for
    /// drag-to-reorder.
    private func taskList(_ items: [TaskItem], compact: Bool) -> some View {
        GeometryReader { viewport in
            // A row counts as hidden once its middle is past an edge.
            let below = rowPositions
                .filter { $0.midY > viewport.size.height }
                .sorted { $0.midY < $1.midY }   // nearest first
            let above = rowPositions
                .filter { $0.midY < 0 }
                .sorted { $0.midY > $1.midY }   // nearest first
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    // Plain VStack (not lazy) so every row reports its position.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { StitchLine() }
                            row(item, compact: compact)
                                .background {
                                    RoundedRectangle(cornerRadius: cs(8), style: .continuous)
                                        .fill(Color.white.opacity(highlightedID == item.id ? 0.38 : 0))
                                        .padding(.horizontal, cs(-8))
                                        .animation(.easeOut(duration: highlightedID == item.id ? 0.2 : 1.2), value: highlightedID)
                                }
                                .background {
                                    // Lifted card under the dragged row (opaque, so rows behind don't show).
                                    if draggingID == item.id {
                                        RoundedRectangle(cornerRadius: cs(8), style: .continuous)
                                            .fill(PaperPalette.sage)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: cs(8), style: .continuous)
                                                    .fill(Color.white.opacity(0.28))
                                            )
                                            .padding(.horizontal, cs(-8))
                                            .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                                    }
                                }
                                .scaleEffect(draggingID == item.id ? 1.02 : 1)
                                .offset(y: dragOffset(for: item.id))
                                .zIndex(draggingID == item.id ? 1 : 0)
                                // The dragged row tracks the pointer exactly; only its neighbours animate.
                                .transaction { if draggingID == item.id { $0.animation = nil } }
                                .gesture(
                                    reorderGesture(for: item, viewportHeight: viewport.size.height) { id in
                                        withAnimation(.smooth(duration: 0.25)) { proxy.scrollTo(id) }
                                    },
                                    including: canReorder ? .all : .subviews
                                )
                                .accessibilityAction(named: "Move up") { moveByStep(item, -1) }
                                .accessibilityAction(named: "Move down") { moveByStep(item, 1) }
                                .transition(.asymmetric(
                                    insertion: .move(edge: .top).combined(with: .opacity),
                                    removal: .opacity))
                                .id(item.id)
                                .background(
                                    GeometryReader { g in
                                        Color.clear.preference(
                                            key: RowPositionKey.self,
                                            value: [RowPosition(id: item.id, midY: g.frame(in: .named(Self.scrollSpace)).midY)]
                                        )
                                    }
                                )
                        }
                    }
                    .padding(.horizontal, cs(compact ? 14 : (isNarrow ? 12 : 18)))
                }
                .coordinateSpace(name: Self.scrollSpace)
                .onChange(of: items.map(\.id)) { _, ids in
                    guard let id = highlightedID, ids.contains(id) else { return }
                    withAnimation(.smooth(duration: 0.35)) { proxy.scrollTo(id, anchor: .center) }
                }
                .onPreferenceChange(RowPositionKey.self) { rowPositions = $0 }
                // Fade whichever edge has tasks beyond it.
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.black.opacity(above.isEmpty ? 1 : 0), .black],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: cs(28))
                        Color.black
                        LinearGradient(colors: [.black, .black.opacity(below.isEmpty ? 1 : 0)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: cs(28))
                    }
                }
                .animation(.easeOut(duration: 0.2), value: above.isEmpty)
                .animation(.easeOut(duration: 0.2), value: below.isEmpty)
            }
        }
    }

    private static let scrollSpace = "taskScroll"

    // MARK: Drag to reorder (local order; Reminders has no API for position)

    private var canReorder: Bool {
        tab == .todo && editingID == nil && tasks.todo.count > 1
    }

    /// Offset that keeps the dragged row under the pointer. Rows report their
    /// natural (un-offset) position, so this self-corrects after every move.
    private func dragOffset(for id: String) -> CGFloat {
        guard draggingID == id, let mid = rowMid(id) else { return 0 }
        return dragPointerY - mid
    }

    private func rowMid(_ id: String) -> CGFloat? {
        rowPositions.first(where: { $0.id == id })?.midY
    }

    private func reorderGesture(for item: TaskItem, viewportHeight: CGFloat,
                                reveal: @escaping (String) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.scrollSpace))
            .updating($isDragGestureActive) { _, active, _ in active = true }
            .onChanged { value in
                guard canReorder else { return }
                if draggingID == nil {
                    guard let mid = rowMid(item.id) else { return }
                    grabDelta = value.startLocation.y - mid
                    if editingID != nil || isAdding { focusedField = nil }
                    withAnimation(.smooth(duration: 0.15)) { draggingID = item.id }
                    reorderHaptic()
                }
                guard draggingID == item.id else { return }
                dragPointerY = value.location.y - grabDelta
                stepIfNeeded(pointerY: value.location.y, viewportHeight: viewportHeight, reveal: reveal)
            }
            .onEnded { _ in endDrag() }
    }

    /// Swaps the dragged row with a neighbour once the pointer passes that
    /// neighbour's middle. Holding near the top/bottom edge keeps stepping (and
    /// scrolling) so tasks can be moved past the visible area.
    private func stepIfNeeded(pointerY: CGFloat, viewportHeight: CGFloat, reveal: (String) -> Void) {
        let list = tasks.todo
        guard let id = draggingID, let i = list.firstIndex(where: { $0.id == id }) else { return }

        var target = i
        var atEdge = false
        if i > 0, let prev = rowMid(list[i - 1].id), dragPointerY < prev {
            target = i - 1
        } else if i < list.count - 1, let next = rowMid(list[i + 1].id), dragPointerY > next {
            target = i + 1
        } else if Date().timeIntervalSince(lastEdgeStep) > 0.28 {
            let edge: CGFloat = 16
            if pointerY < edge, i > 0 { target = i - 1; atEdge = true }
            if pointerY > viewportHeight - edge, i < list.count - 1 { target = i + 1; atEdge = true }
        }
        guard target != i else { return }

        withAnimation(.smooth(duration: 0.2)) { tasks.moveTask(id: id, toIndex: target) }
        reorderHaptic()
        if atEdge {
            lastEdgeStep = Date()
            // Reveal the row beyond the dragged one, so there's room to keep going.
            let beyond = target + (target > i ? 1 : -1)
            reveal(list.indices.contains(beyond) ? list[beyond].id : id)
        }
    }

    private func endDrag() {
        guard draggingID != nil else { return }
        withAnimation(.smooth(duration: 0.22)) {
            draggingID = nil
            dragPointerY = 0
        }
    }

    /// VoiceOver / keyboard alternative to dragging.
    private func moveByStep(_ item: TaskItem, _ delta: Int) {
        guard canReorder, let i = tasks.todo.firstIndex(where: { $0.id == item.id }) else { return }
        withAnimation(.smooth(duration: 0.2)) { tasks.moveTask(id: item.id, toIndex: i + delta) }
    }

    private func reorderHaptic() {
        if Defaults[.enableHaptics] {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private var accessPrompt: some View {
        VStack(spacing: cs(8)) {
            Text(tasks.authorizationStatus == .notDetermined
                 ? "Allow Reminders access to see your tasks."
                 : "Reminders access is turned off.")
                .font(.system(size: cs(13)))
                .foregroundStyle(PaperPalette.inkSecondary)
            if tasks.authorizationStatus == .notDetermined {
                Button("Allow Access") { Task { await tasks.requestAccess() } }
            } else {
                Button("Open Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Row

    private func row(_ item: TaskItem, compact: Bool) -> some View {
        HStack(alignment: compact ? .center : .top, spacing: cs(10)) {
            CheckCircle(isOn: item.isCompleted) {
                tasks.setCompleted(item, !item.isCompleted)
            }
            .accessibilityLabel(item.isCompleted ? "Mark \(item.title) as not done" : "Mark \(item.title) as done")

            if compact {
                HStack(spacing: cs(10)) {
                    titleView(item, compact: true)
                    TaskMeta(item: item, selectedDay: tasks.selectedDate, hiddenListID: hiddenListID,
                             focusedMinutes: focus.focusedMinutes(for: item.id),
                             plannedMinutes: tasks.plannedMinutes[item.id])
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: cs(2.5)) {
                    titleView(item, compact: false)
                    TaskMeta(item: item, selectedDay: tasks.selectedDate, hiddenListID: hiddenListID,
                             focusedMinutes: focus.focusedMinutes(for: item.id),
                             plannedMinutes: tasks.plannedMinutes[item.id])
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: cs(isNarrow ? 6 : 8)) {
                if editingID == item.id {
                    iconButton("checkmark", label: "Save name", size: rowIconSize, box: rowIconBox) { finishEditing(save: true) }
                } else {
                    if showsFocusButton && !item.isCompleted {
                        let isFocusing = focus.taskID == item.id && focus.phase == .running
                        iconButton(isFocusing ? "pause.fill" : "play.fill",
                                   label: isFocusing ? "Pause focus" : "Focus on \(item.title)",
                                   size: rowIconSize, box: rowIconBox) {
                            focus.toggle(task: item)
                        }
                    }
                    iconButton("square.and.pencil", label: "Rename \(item.title)", size: rowIconSize, box: rowIconBox) { startEditing(item) }
                }
                actionsMenu(item)
            }
        }
        .padding(.vertical, cs(compact ? 4 : 5.5))
        .contentShape(Rectangle())
        .contextMenu { taskMenuItems(item) }
    }

    @ViewBuilder
    private func titleView(_ item: TaskItem, compact: Bool) -> some View {
        if editingID == item.id {
            TextField("Task name", text: $editingTitle)
                .textFieldStyle(.plain)
                .font(.system(size: cs(14)))
                .focused($focusedField, equals: .edit(item.id))
                .onSubmit { finishEditing(save: true) }
                .onExitCommand { finishEditing(save: false) }
        } else {
            Text(item.title)
                .font(.system(size: cs(14)))
                .strikethrough(item.isCompleted, color: PaperPalette.inkSecondary)
                .foregroundStyle(item.isCompleted ? PaperPalette.inkSecondary : PaperPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func actionsMenu(_ item: TaskItem) -> some View {
        Menu {
            taskMenuItems(item)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: cs(rowIconSize + 0.5), weight: .semibold))
                .frame(width: cs(rowIconBox), height: cs(rowIconBox))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More actions for \(item.title)")
    }

    /// Items shared by the ··· button and right-click on a task.
    @ViewBuilder
    private func taskMenuItems(_ item: TaskItem) -> some View {
            Button("Rename") { startEditing(item) }
            if showsFocusButton && !item.isCompleted {
                Button("Focus on this task") { focus.start(task: item) }
            }
            Divider()
            Menu("Priority") {
                ForEach(TaskPriority.allCases.reversed()) { p in
                    Button { tasks.setPriority(item, p) } label: {
                        if p == item.priority { Label(p.label, systemImage: "checkmark") } else { Text(p.label) }
                    }
                }
            }
            Menu("Due date") {
                Button("Today") { tasks.setDueDay(item, Date()) }
                Button("Tomorrow") {
                    tasks.setDueDay(item, Calendar.current.date(byAdding: .day, value: 1, to: Date()))
                }
                Button("Next week") {
                    tasks.setDueDay(item, Calendar.current.date(byAdding: .day, value: 7, to: Date()))
                }
                Button("Custom date…") { openDueDatePicker(for: item) }
                Divider()
                Button("No date") { tasks.setDueDay(item, nil) }
            }
            Menu("Duration") {
                ForEach([15, 25, 30, 45, 60, 90, 120], id: \.self) { minutes in
                    Button {
                        tasks.setPlannedMinutes(item.id, minutes)
                    } label: {
                        if tasks.plannedMinutes[item.id] == minutes {
                            Label(TaskDurationParser.label(minutes), systemImage: "checkmark")
                        } else {
                            Text(TaskDurationParser.label(minutes))
                        }
                    }
                }
                if tasks.plannedMinutes[item.id] != nil {
                    Divider()
                    Button("No duration") { tasks.setPlannedMinutes(item.id, nil) }
                }
            }
            Menu("Time") {
                ForEach([9, 12, 15, 18, 21], id: \.self) { hour in
                    Button(timeLabel(hour: hour)) { tasks.setDueTime(item, hour: hour) }
                }
                if item.dueTime != nil {
                    Divider()
                    Button("Remove time") { tasks.setDueTime(item, hour: nil) }
                }
            }
            if tasks.lists.count > 1 {
                Menu("Move to list") {
                    ForEach(tasks.lists) { list in
                        Button { tasks.move(item, toListID: list.id) } label: {
                            if list.id == item.listID { Label(list.title, systemImage: "checkmark") } else { Text(list.title) }
                        }
                    }
                }
            }
            Divider()
            Button("Delete", role: .destructive) { tasks.delete(item) }
    }

    private func timeLabel(hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: Add bar

    private func addBar(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: cs(6)) {
            if parsedInput != nil || parsedDuration != nil || parsedPriority != nil || parsedList != nil {
                duePills(parsedInput, parsedDuration)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            addField(compact: compact)
        }
        .animation(.smooth(duration: 0.2), value: parsedInput)
        .animation(.smooth(duration: 0.2), value: parsedDuration)
        .animation(.smooth(duration: 0.2), value: parsedPriority)
        .animation(.smooth(duration: 0.2), value: parsedList)
    }

    private func addField(compact: Bool) -> some View {
        HStack(spacing: cs(8)) {
            Image(systemName: addedMessage == nil ? "plus" : "checkmark")
                .font(.system(size: cs(11.5), weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
            ZStack(alignment: .leading) {
                if newTitle.isEmpty {
                    Text(addedMessage ?? "Add a task…")
                        .foregroundStyle(addedMessage == nil ? PaperPalette.inkSecondary : PaperPalette.ink)
                        .contentTransition(.opacity)
                        .allowsHitTesting(false)
                }
                if isAdding {
                    TextField("", text: $newTitle)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .add)
                        .onSubmit {
                            let parsed = parsedInput
                            if let added = tasks.addTask(title: parsed?.title ?? textWithoutDuration,
                                                         due: parsed?.due,
                                                         minutes: parsedDuration?.minutes,
                                                         priority: parsedPriority?.priority,
                                                         listID: parsedList?.listID) {
                                confirmAdded(added)
                            }
                            newTitle = ""   // stay in the field for quick entry
                            dismissedDateText = nil
                            dismissedTimeText = nil
                            dismissedDurationText = nil
                            dismissedPriorityText = nil
                            dismissedListText = nil
                        }
                        .onExitCommand {
                            newTitle = ""
                            focusedField = nil
                        }
                        .accessibilityLabel("New task")
                }
            }
            .font(.system(size: cs(13.5)))
            Spacer(minLength: 0)
            if !compact && !isAdding && addedMessage == nil && tasks.todo.count > 1 {
                Text("Drag to reorder")
                    .font(.system(size: cs(11)))
                    .foregroundStyle(PaperPalette.inkSecondary)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, cs(12))
        .padding(.vertical, cs(compact ? 4 : 6))
        .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: cs(10), style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if !isAdding { startAdding() } }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Add a task")
    }

    // MARK: Add feedback

    /// Haptic tick, ✓ + "Added to <list>" in the add bar, and a fading glow on the
    /// new row (which is also scrolled into view once Reminders returns it).
    private func confirmAdded(_ added: TasksManager.AddedTask) {
        let id = added.id
        if Defaults[.enableHaptics] {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        var message = added.isDefaultList || added.listName.isEmpty ? "Added" : "Added to \(added.listName)"
        // Added to another day: say where it went, since it won't appear in this list.
        if !Calendar.current.isDate(added.dueDay, inSameDayAs: tasks.selectedDate) {
            message += " · " + Self.relativeDay(added.dueDay)
        }
        withAnimation(.smooth(duration: 0.2)) {
            addedMessage = message
            highlightedID = id
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            // Only clear if no newer task replaced the feedback meanwhile.
            guard highlightedID == id else { return }
            withAnimation(.smooth(duration: 0.3)) {
                addedMessage = nil
                highlightedID = nil
            }
        }
    }

    // MARK: Natural-language dates

    /// Date found in what the user is typing, unless they dismissed it.
    // Parsed in order, each on what the previous one left:
    // #List → priority → duration → date. The rest is the title.

    /// "Plan launch #Work" → the Work list (only lists that exist).
    private var parsedList: ParsedListTag? {
        guard isAdding, let parsed = TaskListTagParser.parse(newTitle, lists: tasks.lists),
              parsed.matchedText != dismissedListText else { return nil }
        return parsed
    }

    private var textWithoutList: String { parsedList?.remaining ?? newTitle }

    /// "Pay rent !!!", "Fix bug urgent", "p2 …" → priority (unless dismissed).
    private var parsedPriority: ParsedPriority? {
        guard isAdding, let parsed = TaskPriorityParser.parse(textWithoutList),
              parsed.matchedText != dismissedPriorityText else { return nil }
        return parsed
    }

    private var textWithoutPriority: String { parsedPriority?.remaining ?? textWithoutList }

    /// "Work for 45 mins" → 45 min (unless dismissed). Parsed before dates.
    private var parsedDuration: ParsedDuration? {
        guard isAdding, let parsed = TaskDurationParser.parse(textWithoutPriority),
              parsed.matchedText != dismissedDurationText else { return nil }
        return parsed
    }

    /// Text left for date detection and the title, after removing the duration.
    private var textWithoutDuration: String { parsedDuration?.remaining ?? textWithoutPriority }

    private var parsedInput: ParsedTaskInput? {
        guard isAdding, let parsed = TaskDateParser.parse(textWithoutDuration),
              parsed.matchedText != dismissedDateText else { return nil }
        if parsed.due.hasTime, parsed.matchedText == dismissedTimeText {
            let day = Calendar.current.startOfDay(for: parsed.due.date)
            return ParsedTaskInput(title: parsed.title, due: ParsedDue(date: day, hasTime: false),
                                   matchedText: parsed.matchedText)
        }
        return parsed
    }

    /// Separate pills above the add bar: date, and time when one was typed.
    /// Each has its own ×: removing the time keeps the date; removing the date
    /// saves the text exactly as typed.
    private func duePills(_ parsedDate: ParsedTaskInput?, _ duration: ParsedDuration?) -> some View {
        FlowLayout(spacing: cs(6), lineSpacing: cs(4)) {
            if let parsed = parsedDate {
            duePill(icon: "calendar",
                    text: Self.relativeDay(parsed.due.date, includeWeekday: true),
                    dismissHelp: "Don't treat this as a date",
                    accessibility: "Due \(Self.relativeDay(parsed.due.date, includeWeekday: true))") {
                dismissedDateText = parsed.matchedText
            }
            if parsed.due.hasTime {
                duePill(icon: "bell",
                        text: parsed.due.date.formatted(date: .omitted, time: .shortened),
                        dismissHelp: "Remove the time",
                        accessibility: "At \(parsed.due.date.formatted(date: .omitted, time: .shortened))") {
                    dismissedTimeText = parsed.matchedText
                }
            }
            }
            if let priority = parsedPriority {
                duePill(icon: "flag.fill",
                        text: priority.priority.label,
                        dismissHelp: "Don't treat this as a priority",
                        accessibility: "\(priority.priority.label) priority") {
                    dismissedPriorityText = priority.matchedText
                }
            }
            if let list = parsedList {
                duePill(icon: TaskMeta.icon(forList: list.listName),
                        text: list.listName,
                        dismissHelp: "Don't put it in this list",
                        accessibility: "In list \(list.listName)") {
                    dismissedListText = list.matchedText
                }
            }
            if let duration {
                duePill(icon: "timer",
                        text: TaskDurationParser.label(duration.minutes),
                        dismissHelp: "Don't treat this as a duration",
                        accessibility: "Focus for \(TaskDurationParser.label(duration.minutes))") {
                    dismissedDurationText = duration.matchedText
                }
            }
        }
        .padding(.leading, cs(2))
    }

    private func duePill(icon: String, text: String, dismissHelp: String, accessibility: String,
                         onDismiss: @escaping () -> Void) -> some View {
        HStack(spacing: cs(4)) {
            Image(systemName: icon)
            Text(text).lineLimit(1)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: cs(8.5), weight: .bold))
                    .frame(width: cs(13), height: cs(13))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(dismissHelp)
            .accessibilityLabel(dismissHelp)
        }
        .font(.system(size: cs(11.5), weight: .medium))
        .padding(.leading, cs(8))
        .padding(.trailing, cs(4))
        .padding(.vertical, cs(3))
        .background(Color.white.opacity(0.4), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibility)
    }

    /// "Today", "Tomorrow", or e.g. "Fri 12 Dec" (year added when it's not this year).
    private static func relativeDay(_ date: Date, includeWeekday: Bool = false) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        var style = Date.FormatStyle().day().month(.abbreviated)
        if includeWeekday { style = style.weekday(.abbreviated) }
        if !cal.isDate(date, equalTo: Date(), toGranularity: .year) { style = style.year() }
        return date.formatted(style)
    }

    // MARK: Month picker

    private func closeMonthPicker() {
        withAnimation(.smooth(duration: 0.18)) {
            showMonthPicker = false
            dueDateTarget = nil
        }
    }

    /// Day-cell size that lets a 6-week month fit below the picker's top offset.
    private func pickerCell(cardHeight: CGFloat, cardWidth: CGFloat, compact: Bool, hasTitle: Bool) -> CGFloat {
        let topOffset: CGFloat = cs(compact ? 4 : 42)
        // Header, weekday row, Today button, spacing and padding (+ title line).
        let chrome: CGFloat = cs(92 + (hasTitle ? 20 : 0))
        let fitHeight = (cardHeight - topOffset - cs(6) - chrome - cs(5 * 4)) / 6
        // 7 columns + 6 gaps + padding + right inset must fit inside the card.
        let fitWidth = (cardWidth - cs(6 * 6 + 24 + 20)) / 7
        return min(cs(compact ? 20 : 24), max(14 * notchScale, min(fitHeight, fitWidth).rounded(.down)))
    }

    private func openDueDatePicker(for item: TaskItem) {
        pickerMonth = item.dueDay ?? tasks.selectedDate
        withAnimation(.smooth(duration: 0.2)) {
            showMonthPicker = false
            dueDateTarget = item
        }
    }

    /// ▶ on rows only when the focus timer card is shown.
    private var showsFocusButton: Bool { !hiddenCards.contains(.focus) }

    /// Hide the list name when it's the default list or the only list.
    private var hiddenListID: String? {
        tasks.lists.count <= 1 ? tasks.lists.first?.id ?? tasks.defaultListID : tasks.defaultListID
    }

    // MARK: Typing / keyboard focus

    private func startAdding() {
        beginTyping()
        isAdding = true
        DispatchQueue.main.async { focusedField = .add }
        endTypingIfFocusFailed()
    }

    private func startEditing(_ item: TaskItem) {
        // Switching to another task saves the one being edited.
        if editingID != nil { saveEditIfChanged() }
        beginTyping()
        editingTitle = item.title
        editingID = item.id
        DispatchQueue.main.async { focusedField = .edit(item.id) }
        endTypingIfFocusFailed()
    }

    /// If the field never actually received focus, don't leave the notch pinned open.
    private func endTypingIfFocusFailed() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if focusedField == nil && isTyping { endTyping() }
        }
    }

    /// Ends a rename. `save: false` (Esc) discards the change.
    private func finishEditing(save: Bool) {
        if save { saveEditIfChanged() }
        editingID = nil
        focusedField = nil
    }

    /// Writes the edited name to Reminders (no-op if empty or unchanged).
    private func saveEditIfChanged() {
        guard let id = editingID,
              let item = tasks.todo.first(where: { $0.id == id }) ?? tasks.completed.first(where: { $0.id == id })
        else { return }
        tasks.rename(item, to: editingTitle)
    }

    private var isTyping: Bool { isAdding || editingID != nil }

    private func beginTyping() {
        (hostWindow as? BoringNotchSkyLightWindow)?.beginKeyboardFocus(owner: Self.focusOwner)
    }

    private func endTyping() {
        isAdding = false
        if editingID != nil {
            saveEditIfChanged()
            editingID = nil
        }
        (hostWindow as? BoringNotchSkyLightWindow)?.endKeyboardFocus(owner: Self.focusOwner)
        syncKeepOpen()
    }

    /// The notch only refuses to collapse while there's unsaved input: a rename in
    /// progress, or text typed into the add field. An empty add field (e.g. right
    /// after pressing Enter) lets the notch close normally when the pointer leaves;
    /// closing removes this view, which ends typing and hands back the keyboard.
    private func syncKeepOpen() {
        let hasDraft = isAdding && !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let keepOpen = editingID != nil || hasDraft || draggingID != nil
        vm.setKeepOpen("tasks", keepOpen)
    }

    // MARK: Helpers

    /// Icon size for the ▶ ✎ ··· buttons on a task row (all drawn the same size).
    private let rowIconSize: CGFloat = 10.5
    private let rowIconBox: CGFloat = 15

    private func iconButton(_ systemName: String, label: String, size: CGFloat = 12, box: CGFloat = 17,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: cs(size), weight: .semibold))
                .frame(width: cs(box), height: cs(box))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Pieces

/// Lays items out left to right and wraps to a new line when out of room
/// (so task details never get cut off or hidden).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// Small month calendar shown from the date pill. Dots mark days with open tasks.
private struct MonthPicker: View {
    @Environment(\.notchScale) var notchScale
    /// Card size value scaled for the notch's design proportions and this screen.
    private func cs(_ value: CGFloat) -> CGFloat { value * cardUIScale * notchScale }
    @Binding var month: Date
    let selected: Date?
    let daysWithTasks: Set<Date>
    let cell: CGFloat
    var title: String? = nil
    let onPick: (Date) -> Void
    let onToday: () -> Void

    private let cal = Calendar.current
    /// Space between day columns / rows.
    private let gap: CGFloat = 6
    private let rowGap: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: cs(6)) {
            if let title {
                Text(title)
                    .font(.system(size: cs(11), weight: .medium))
                    .foregroundStyle(PaperPalette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: cell * 7 + gap * 6, alignment: .leading)
            }
            HStack(spacing: cs(6)) {
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.system(size: cs(13), weight: .semibold))
                Spacer(minLength: cs(8))
                stepButton("chevron.left", label: "Previous month") { shiftMonth(-1) }
                stepButton("chevron.right", label: "Next month") { shiftMonth(1) }
            }

            HStack(spacing: cs(gap)) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: cs(9.5), weight: .semibold))
                        .foregroundStyle(PaperPalette.inkSecondary)
                        .frame(width: cell)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: cs(gap)), count: 7), spacing: cs(rowGap)) {
                ForEach(Array(gridDays.enumerated()), id: \.offset) { _, day in
                    if let day {
                        dayCell(day)
                    } else {
                        Color.clear.frame(width: cell, height: cell)
                    }
                }
            }

            Button("Today", action: onToday)
                .buttonStyle(.plain)
                .font(.system(size: cs(11), weight: .semibold))
                .padding(.horizontal, cs(8))
                .padding(.vertical, cs(3))
                .background(Color.black.opacity(0.07), in: Capsule())
        }
        .padding(cs(12))
        .background(PaperBackground(cornerRadius: cs(14)))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .fixedSize()
    }

    private func dayCell(_ day: Date) -> some View {
        let isSelected = selected.map { cal.isDate(day, inSameDayAs: $0) } ?? false
        let isToday = cal.isDateInToday(day)
        let hasTasks = daysWithTasks.contains(day)
        return Button { onPick(day) } label: {
            ZStack {
                if isSelected {
                    Circle().fill(PaperPalette.ink.opacity(0.85))
                } else if isToday {
                    Circle().strokeBorder(PaperPalette.ink.opacity(0.6), lineWidth: 1)
                }
                Text("\(cal.component(.day, from: day))")
                    .font(.system(size: cell * 0.46, weight: isToday || isSelected ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? PaperPalette.sage : PaperPalette.ink)
                if hasTasks && !isSelected {
                    Circle()
                        .fill(PaperPalette.ink.opacity(0.7))
                        .frame(width: cs(3.5), height: cs(3.5))
                        .offset(y: cell * 0.32)
                }
            }
            .frame(width: cell, height: cell)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted) + (hasTasks ? ", has tasks" : ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func stepButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: cs(11), weight: .semibold))
                .frame(width: cs(18), height: cs(18))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func shiftMonth(_ delta: Int) {
        if let next = cal.date(byAdding: .month, value: delta, to: month) { month = next }
    }

    /// Weekday initials starting from the user's first weekday.
    private var weekdaySymbols: [String] {
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        let start = cal.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }

    /// Leading blanks, then every day of the month (start-of-day dates).
    private var gridDays: [Date?] {
        guard let interval = cal.dateInterval(of: .month, for: month),
              let count = cal.range(of: .day, in: .month, for: month)?.count
        else { return [] }
        let first = interval.start
        let leading = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        let days = (0..<count).compactMap { cal.date(byAdding: .day, value: $0, to: first) }
        return Array(repeating: nil, count: leading) + days.map { Optional($0) }
    }
}

struct RowPosition: Equatable {
    let id: String
    let midY: CGFloat
}

private struct RowPositionKey: PreferenceKey {
    static let defaultValue: [RowPosition] = []
    static func reduce(value: inout [RowPosition], nextValue: () -> [RowPosition]) {
        value.append(contentsOf: nextValue())
    }
}

struct CheckCircle: View {
    @Environment(\.notchScale) var notchScale
    /// Card size value scaled for the notch's design proportions and this screen.
    private func cs(_ value: CGFloat) -> CGFloat { value * cardUIScale * notchScale }
    let isOn: Bool
    var tint: Color = PaperPalette.sage
    var size: CGFloat = 19.5
    let action: () -> Void
    @State private var pressed = false

    var body: some View {
        Button {
            // Fill briefly before the row moves to the other tab.
            withAnimation(.snappy(duration: 0.18)) { pressed = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                action()
                pressed = false
            }
        } label: {
            ZStack {
                Circle().strokeBorder(PaperPalette.ink.opacity(0.85), lineWidth: 1.6)
                if isOn != pressed {
                    Circle().fill(PaperPalette.ink.opacity(0.85)).padding(cs(4))
                    Image(systemName: "checkmark")
                        .font(.system(size: cs(9), weight: .bold))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: cs(size), height: cs(size))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct TaskMeta: View {
    @Environment(\.notchScale) var notchScale
    /// Card size value scaled for the notch's design proportions and this screen.
    private func cs(_ value: CGFloat) -> CGFloat { value * cardUIScale * notchScale }
    let item: TaskItem
    let selectedDay: Date
    /// List whose name isn't shown (the default list says nothing useful).
    let hiddenListID: String?
    var focusedMinutes: Int = 0
    var plannedMinutes: Int? = nil
    /// Narrow cards show only the most important details.
    var maxParts: Int? = nil

    var body: some View {
        let parts = metaParts
        if !parts.isEmpty {
            // Every detail is shown; they wrap onto another line when the card is narrow.
            FlowLayout(spacing: cs(10), lineSpacing: cs(3)) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    HStack(spacing: cs(4)) {
                        Image(systemName: part.icon)
                        Text(part.text).fontWeight(part.bold ? .semibold : .regular)
                    }
                    .foregroundStyle(part.warning ? Color(red: 0.62, green: 0.16, blue: 0.12) : PaperPalette.inkSecondary)
                }
            }
            .font(.system(size: cs(11)))
        }
    }

    private struct Part { let icon: String; let text: String; var bold = false; var warning = false }

    private var metaParts: [Part] {
        var parts: [Part] = []
        // ⏱ planned length ("45 min"), progress once focused ("20 / 45 min"), or just time focused.
        if let planned = plannedMinutes {
            let text = focusedMinutes > 0
                ? "\(focusedMinutes) / \(TaskDurationParser.label(planned))"
                : TaskDurationParser.label(planned)
            parts.append(Part(icon: "timer", text: text, bold: focusedMinutes >= planned))
        } else if focusedMinutes > 0 {
            parts.append(Part(icon: "timer", text: "Focused · \(focusedMinutes) min"))
        }
        let cal = Calendar.current
        if let day = item.dueDay, !cal.isDate(day, inSameDayAs: selectedDay) {
            let overdue = !item.isCompleted && day < cal.startOfDay(for: Date())
            let text = cal.isDateInYesterday(day) ? "Yesterday" : day.formatted(.dateTime.day().month(.abbreviated))
            parts.append(Part(icon: "calendar", text: overdue ? "Overdue · \(text)" : text, warning: overdue))
        }
        if item.priority != .none {
            parts.append(Part(icon: "flag.fill", text: item.priority.label, bold: item.priority == .high))
        }
        if !item.listName.isEmpty, item.listID != hiddenListID {
            parts.append(Part(icon: Self.icon(forList: item.listName), text: item.listName))
        }
        if let location = item.location {
            parts.append(Part(icon: "mappin", text: location))
        }
        if let time = item.dueTime {
            parts.append(Part(icon: "bell", text: time.formatted(date: .omitted, time: .shortened)))
        }
        if let repeats = item.repeatSummary {
            parts.append(Part(icon: "arrow.triangle.2.circlepath", text: repeats))
        }
        return parts
    }

    /// Picks an icon from the Reminders list name (Reminders doesn't expose list icons).
    static func icon(forList name: String) -> String {
        let n = name.lowercased()
        let map: [(keys: [String], icon: String)] = [
            (["work", "job", "office"], "briefcase"),
            (["home", "house", "family"], "house"),
            (["health", "gym", "fitness", "workout"], "heart"),
            (["shop", "grocer", "buy"], "cart"),
            (["school", "study", "class", "learn"], "book"),
            (["personal", "me"], "person"),
            (["travel", "trip"], "airplane"),
            (["money", "finance", "bill"], "creditcard"),
        ]
        return map.first { entry in entry.keys.contains { n.contains($0) } }?.icon ?? "list.bullet"
    }
}

/// Sewn-seam look: short rounded stitches with a faint highlight just below,
/// so they read as pressed into the paper rather than printed on it.
struct StitchLine: View {
    @Environment(\.notchScale) var notchScale
    /// Card size value scaled for the notch's design proportions and this screen.
    private func cs(_ value: CGFloat) -> CGFloat { value * cardUIScale * notchScale }
    var body: some View {
        ZStack {
            Line()
                .stroke(Color.white.opacity(0.16),
                        style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3.5, 3]))
                .offset(y: 0.7)
            Line()
                .stroke(PaperPalette.ink.opacity(0.2),
                        style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3.5, 3]))
        }
        .frame(height: cs(2))
        .accessibilityHidden(true)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: rect.minX, y: rect.midY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
        }
    }
}

/// Exposes the hosting NSWindow so the panel can toggle keyboard focus.
/// Reports only when the view moves into a window, so it never loops on re-render.
private struct WindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ResolvingView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ResolvingView: NSView {
        var onResolve: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = self.window
            DispatchQueue.main.async { [onResolve] in onResolve?(window) }
        }
    }
}
