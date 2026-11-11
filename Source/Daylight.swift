import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DailyTask: Codable, Identifiable {
    var id = UUID()
    var title: String
    var completed = false
    var archived = false
    var later = false
    init(title: String, completed: Bool = false, later: Bool = false) { self.title = title; self.completed = completed; self.later = later }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        completed = try c.decodeIfPresent(Bool.self, forKey: .completed) ?? false
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        later = try c.decodeIfPresent(Bool.self, forKey: .later) ?? false
    }
    var isBlank: Bool { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

struct DailyTasks: Codable {
    var items: [DailyTask] = []
    var activeID: UUID?
}

@MainActor final class FocusState: ObservableObject {
    @Published private(set) var tasks = DailyTasks()
    @Published var draft = ""
    var activeTask: DailyTask? { tasks.items.first { $0.id == tasks.activeID } }
    var task: String {
        get { activeTask?.title ?? "" }
        set {
            guard let index = tasks.items.firstIndex(where: { $0.id == tasks.activeID }) else { return }
            tasks.items[index].title = String(newValue.prefix(180))
            tasks.items[index].completed = false
            save(); onContentChange?()
        }
    }
    var completed: Bool {
        get { activeTask?.completed ?? false }
        set {
            guard let index = tasks.items.firstIndex(where: { $0.id == tasks.activeID }) else { return }
            tasks.items[index].completed = newValue
            save(); onScheduleChange?()
        }
    }
    func addTask(_ title: String, later: Bool = false) {
        checkDay()
        let cleaned = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
        guard !cleaned.isEmpty else { return }
        let item = DailyTask(title: cleaned, later: later)
        tasks.items.append(item)
        if tasks.activeID == nil && !later { tasks.activeID = item.id; onScheduleChange?() }
        save()
    }
    func focusTask(_ id: UUID) {
        checkDay()
        guard let index = tasks.items.firstIndex(where: { $0.id == id }) else { return }
        tasks.items[index].completed = false
        tasks.items[index].archived = false
        tasks.items[index].later = false
        tasks.activeID = id
        tidyBlanks()
        save(); onScheduleChange?()
    }
    var openTasks: [DailyTask] { tasks.items.filter { !$0.archived && !$0.completed && $0.id != tasks.activeID } }
    var todayTasks: [DailyTask] { openTasks.filter { !$0.later } }
    var laterTasks: [DailyTask] { openTasks.filter { $0.later } }
    func section(of id: UUID) -> [DailyTask] { laterTasks.contains { $0.id == id } ? laterTasks : todayTasks }
    // Moving between Today and Later from a button lands the task at the end of the other section.
    func setLater(_ id: UUID, _ later: Bool) { move(id, toLater: later, at: .max) }
    /// Put a task into Today or Later at a position within that section.
    func move(_ id: UUID, toLater later: Bool, at index: Int) {
        let target = (later ? laterTasks : todayTasks).filter { $0.id != id }
        guard let i = tasks.items.firstIndex(where: { $0.id == id }) else { return }
        var item = tasks.items.remove(at: i)
        item.later = later
        if index < target.count, let a = tasks.items.firstIndex(where: { $0.id == target[index].id }) {
            tasks.items.insert(item, at: a)
        } else if let last = target.last, let a = tasks.items.firstIndex(where: { $0.id == last.id }) {
            tasks.items.insert(item, at: a + 1)
        } else {
            tasks.items.append(item)
        }
        if later && id == tasks.activeID { tasks.activeID = nil; onScheduleChange?() }
        save()
    }
    var completedTasks: [DailyTask] { tasks.items.filter { !$0.archived && $0.completed && $0.id != tasks.activeID } }
    var archivedTasks: [DailyTask] { tasks.items.filter { $0.archived } }
    func rename(_ id: UUID, _ title: String) {
        guard let i = tasks.items.firstIndex(where: { $0.id == id }) else { return }
        tasks.items[i].title = String(title.prefix(180))
        save(); if id == tasks.activeID { onContentChange?() }
    }
    func toggleCompleted(_ id: UUID) {
        guard let i = tasks.items.firstIndex(where: { $0.id == id }) else { return }
        tasks.items[i].completed.toggle()
        save(); if id == tasks.activeID { onScheduleChange?() }
    }
    // Reorder among visible (non-archived, non-active) tasks; array order is priority.
    func move(_ id: UUID, by offset: Int) {
        let visible = section(of: id)
        guard let pos = visible.firstIndex(where: { $0.id == id }) else { return }
        let target = pos + offset
        guard visible.indices.contains(target),
              let from = tasks.items.firstIndex(where: { $0.id == id }),
              let to = tasks.items.firstIndex(where: { $0.id == visible[target].id }) else { return }
        tasks.items.swapAt(from, to)
        save()
    }
    var draggingID: UUID?
    // Drag-to-reorder: put the dragged task where the hovered task is.
    func reorder(_ id: UUID, onto target: UUID) {
        guard id != target,
              let from = tasks.items.firstIndex(where: { $0.id == id }),
              let to = tasks.items.firstIndex(where: { $0.id == target }) else { return }
        let item = tasks.items.remove(at: from)
        tasks.items.insert(item, at: to)
        save()
    }
    /// Commit a drag: place `id` at `targetIndex` within its section (Today or Later).
    func place(_ id: UUID, at targetIndex: Int) {
        let open = section(of: id)
        guard let from = open.firstIndex(where: { $0.id == id }), targetIndex != from, open.indices.contains(targetIndex),
              let src = tasks.items.firstIndex(where: { $0.id == id }) else { return }
        let anchor = open[targetIndex].id
        let item = tasks.items.remove(at: src)
        guard let a = tasks.items.firstIndex(where: { $0.id == anchor }) else { tasks.items.insert(item, at: src); return }
        tasks.items.insert(item, at: targetIndex > from ? a + 1 : a)
        save()
    }
    func moveToTop(_ id: UUID) {
        guard let from = tasks.items.firstIndex(where: { $0.id == id }) else { return }
        let item = tasks.items.remove(at: from)
        tasks.items.insert(item, at: 0)
        save()
    }
    func archive(_ id: UUID, announce: Bool = true) {
        guard let i = tasks.items.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = tasks.activeID == id
        tasks.items[i].archived = true
        if wasActive { tasks.activeID = nil; onScheduleChange?() }
        save(); onContentChange?()
        if announce {
            showToast("Archived", tasks.items[i].title) { [weak self] in
                self?.restore(id)
                if wasActive { self?.focusTask(id) }
            }
        }
    }
    func setCompleted(_ id: UUID, _ done: Bool) {
        guard let i = tasks.items.firstIndex(where: { $0.id == id }), tasks.items[i].completed != done else { return }
        tasks.items[i].completed = done
        save(); if id == tasks.activeID { onScheduleChange?() }
        if done { showToast("Completed", tasks.items[i].title) { [weak self] in self?.setCompleted(id, false) } }
    }
    struct Toast: Identifiable { let id = UUID(); let verb: String; let title: String; let undo: () -> Void }
    @Published var toast: Toast?
    func showToast(_ verb: String, _ title: String, undo: @escaping () -> Void) {
        let t = Toast(verb: verb, title: title, undo: undo)
        withAnimation(.easeOut(duration: 0.18)) { toast = t }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if self?.toast?.id == t.id { withAnimation(.easeIn(duration: 0.18)) { self?.toast = nil } }
        }
    }
    func undoToast() {
        guard let t = toast else { return }
        withAnimation(.easeIn(duration: 0.15)) { toast = nil }
        t.undo()
    }
    func restore(_ id: UUID) {
        guard let i = tasks.items.firstIndex(where: { $0.id == id }) else { return }
        tasks.items[i].archived = false
        save()
    }
    // Only ever called from an explicit user action in the Archived section.
    func deleteForever(_ id: UUID) {
        tasks.items.removeAll { $0.id == id }
        save()
    }
    // Blank tasks (e.g. focus text cleared) get archived, never deleted.
    func tidyBlanks() {
        for i in tasks.items.indices where tasks.items[i].isBlank && tasks.items[i].id != tasks.activeID {
            tasks.items[i].archived = true
        }
    }
    @Published var interval = 15 { didSet { UserDefaults.standard.set(interval, forKey: "ghost.interval"); onScheduleChange?() } }
    @Published var duration = 7 { didSet { UserDefaults.standard.set(duration, forKey: "ghost.duration"); onScheduleChange?() } }
    @Published var backgroundOpacity = 0.15 { didSet { UserDefaults.standard.set(backgroundOpacity, forKey: "backgroundOpacity") } }
    @Published var visible = true
    @Published var day = ""
    var onScheduleChange: (() -> Void)?
    var onContentChange: (() -> Void)?
    var onPreview: (() -> Void)?
    var onStartFocusing: (() -> Void)?
    var onVisibility: (() -> Void)?
    private var loading = false
    static func today() -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }
    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "ghost.interval") != nil { interval = min(180, max(1, defaults.integer(forKey: "ghost.interval"))) }
        if defaults.object(forKey: "ghost.duration") != nil { duration = min(30, max(3, defaults.integer(forKey: "ghost.duration"))) }
        if defaults.object(forKey: "backgroundOpacity") != nil { backgroundOpacity = min(0.7, max(0, defaults.double(forKey: "backgroundOpacity"))) }
        loadDay()
    }
    // Tasks persist across days under one key; nothing is ever cleared automatically.
    static let storeKey = "tasks"
    func checkDay() { day = Self.today() }
    func loadDay() {
        loading = true
        day = Self.today()
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.storeKey), let saved = try? JSONDecoder().decode(DailyTasks.self, from: data) {
            tasks = saved
        } else {
            tasks = Self.migrateLatestDay(defaults)
        }
        if !tasks.items.contains(where: { $0.id == tasks.activeID && !$0.archived }) {
            tasks.activeID = tasks.items.first { !$0.archived && !$0.isBlank && !$0.later }?.id
        }
        tidyBlanks()
        loading = false
        save(); onContentChange?()
    }
    // One-time migration from the old per-day keys: carry over the most recent day that had tasks.
    // Old per-day keys are left in place untouched.
    static func migrateLatestDay(_ defaults: UserDefaults) -> DailyTasks {
        let all = defaults.dictionaryRepresentation()
        for key in all.keys.filter({ $0.hasPrefix("tasks.") }).sorted(by: >) {
            if let data = all[key] as? Data, let saved = try? JSONDecoder().decode(DailyTasks.self, from: data), !saved.items.isEmpty { return saved }
        }
        for key in all.keys.filter({ $0.hasPrefix("task.") }).sorted(by: >) {
            let day = String(key.dropFirst("task.".count))
            if let title = all[key] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let previous = DailyTask(title: title, completed: defaults.bool(forKey: "done.\(day)"))
                return DailyTasks(items: [previous], activeID: previous.id)
            }
        }
        return DailyTasks()
    }
    func save() {
        guard !loading else { return }
        if let data = try? JSONEncoder().encode(tasks) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }
    var hasTask: Bool { !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func toggleVisible() { visible.toggle(); onVisibility?() }
}

let ink = Color(nsColor: .labelColor)
final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

// A native vector avatar keeps its silhouette crisp at any display resolution.
final class GhostView: NSView {
    var onClick: (() -> Void)?
    private var dragged = false
    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let body = NSBezierPath()
        body.move(to: NSPoint(x: 12, y: 67))
        body.line(to: NSPoint(x: 12, y: 34))
        body.curve(to: NSPoint(x: 64, y: 34), controlPoint1: NSPoint(x: 12, y: -1), controlPoint2: NSPoint(x: 64, y: -1))
        body.line(to: NSPoint(x: 64, y: 67))
        body.curve(to: NSPoint(x: 51, y: 66), controlPoint1: NSPoint(x: 62, y: 78), controlPoint2: NSPoint(x: 55, y: 55))
        body.curve(to: NSPoint(x: 38, y: 66), controlPoint1: NSPoint(x: 47, y: 79), controlPoint2: NSPoint(x: 42, y: 79))
        body.curve(to: NSPoint(x: 25, y: 66), controlPoint1: NSPoint(x: 34, y: 54), controlPoint2: NSPoint(x: 29, y: 54))
        body.curve(to: NSPoint(x: 12, y: 67), controlPoint1: NSPoint(x: 20, y: 79), controlPoint2: NSPoint(x: 14, y: 77))
        body.close()
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.shadowBlurRadius = 4; shadow.shadowOffset = NSSize(width: 0, height: -1); shadow.set()
        NSColor.white.withAlphaComponent(0.94).setFill(); body.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.7).setStroke(); body.lineWidth = 1.2; body.stroke()
        NSColor(white: 0.14, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 25, y: 33, width: 7, height: 10)).fill()
        NSBezierPath(ovalIn: NSRect(x: 44, y: 33, width: 7, height: 10)).fill()
        let smile = NSBezierPath(); smile.move(to: NSPoint(x: 34, y: 47)); smile.curve(to: NSPoint(x: 42, y: 47), controlPoint1: NSPoint(x: 36, y: 51), controlPoint2: NSPoint(x: 40, y: 51)); smile.lineWidth = 1.6; smile.lineCapStyle = .round; smile.stroke()
    }
    override func mouseDown(with event: NSEvent) { dragged = false }
    override func mouseDragged(with event: NSEvent) { dragged = true; window?.performDrag(with: event) }
    override func mouseUp(with event: NSEvent) { if !dragged { onClick?() } }
}

struct Reminder: View {
    @ObservedObject var state: FocusState
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Today's priority is").font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.85))
            Text(state.task).font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(.white).lineLimit(7).minimumScaleFactor(0.6)
        }
        .shadow(color: .black.opacity(0.85), radius: 3, x: 0, y: 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.black.opacity(state.backgroundOpacity))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct FocusButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 18).frame(height: 34)
            .foregroundStyle(scheme == .dark ? Color.black : Color.white)
            .background(ink.opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.25), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - UI primitives (Linear-style: quiet by default, revealed on hover, pointer on everything clickable)

extension View {
    @ViewBuilder func pointer() -> some View {
        if #available(macOS 15, *) { self.pointerStyle(.link) }
        else { self.onHover { $0 ? NSCursor.pointingHand.set() : NSCursor.arrow.set() } }
    }
    @ViewBuilder func grabCursor(active: Bool = false) -> some View {
        if #available(macOS 15, *) { self.pointerStyle(active ? .grabActive : .grabIdle) }
        else { self.onHover { $0 ? (active ? NSCursor.closedHand : NSCursor.openHand).set() : NSCursor.arrow.set() } }
    }
}

/// Borderless button that gets a soft fill on hover / press and a pointer cursor.
struct GhostButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false
    func makeBody(configuration: Configuration) -> some View { GhostButtonBody(configuration: configuration, prominent: prominent, destructive: destructive) }
    struct GhostButtonBody: View {
        let configuration: Configuration
        let prominent: Bool
        let destructive: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(destructive && hovering ? Color.red : (prominent || hovering ? ink : Color.secondary))
                .padding(.horizontal, 7).frame(minHeight: 24)
                .background(ink.opacity(configuration.isPressed ? 0.12 : (hovering ? 0.07 : 0)), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .opacity(enabled ? 1 : 0.35)
                .onHover { hovering = $0 }
                .pointer()
        }
    }
}

/// Six-dot drag grip.
struct Grip: View {
    var body: some View {
        Canvas { ctx, _ in
            for r in 0..<3 { for c in 0..<2 {
                ctx.fill(Path(ellipseIn: CGRect(x: CGFloat(c) * 4, y: CGFloat(r) * 4, width: 2.2, height: 2.2)), with: .color(Color(nsColor: .tertiaryLabelColor)))
            } }
        }.frame(width: 6.2, height: 10.2)
    }
}

/// Round completion checkbox; hints a check on hover.
struct CheckCircle: View {
    let done: Bool
    var size: CGFloat = 15
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(Color.secondary.opacity(done ? 0 : (hovering ? 0.9 : 0.55)), lineWidth: 1.3)
                if done { Circle().fill(Color.secondary.opacity(0.75)) }
                Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(done ? Color(nsColor: .windowBackgroundColor) : Color.secondary)
                    .opacity(done ? 1 : (hovering ? 0.8 : 0))
            }.frame(width: size, height: size).padding(4).contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }.pointer()
        .help(done ? "Mark as not done" : "Mark as done")
        .accessibilityLabel(done ? "Mark as not done" : "Mark as done")
    }
}

struct RowHeightsKey: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) { value.merge(nextValue()) { $1 } }
}

struct RowFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue()) { $1 } }
}

struct CardFramesKey: PreferenceKey {
    static var defaultValue: [Bool: CGRect] = [:]
    static func reduce(value: inout [Bool: CGRect], nextValue: () -> [Bool: CGRect]) { value.merge(nextValue()) { $1 } }
}

struct TaskDropDelegate: DropDelegate {
    let state: FocusState
    let target: UUID
    func dropEntered(info: DropInfo) {
        guard let id = state.draggingID, id != target else { return }
        withAnimation(.easeInOut(duration: 0.15)) { state.reorder(id, onto: target) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { state.draggingID = nil; return true }
}

// MARK: - Task row

struct TaskRow: View {
    @ObservedObject var state: FocusState
    let item: DailyTask
    let isFirst: Bool
    let isLast: Bool
    var isDragging = false
    var anyDragging = false
    var onDragChanged: (CGFloat) -> Void = { _ in }
    var onDragEnded: () -> Void = {}
    @State private var hovering = false
    @State private var text = ""
    @SwiftUI.FocusState private var editing: Bool
    var body: some View {
        HStack(spacing: 6) {
            Grip()
                .frame(width: 14, height: 26).contentShape(Rectangle())
                .opacity(hovering || isDragging ? 1 : 0)
                .grabCursor(active: isDragging)
                .help("Drag to reorder")
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { value in NSCursor.closedHand.set(); onDragChanged(value.translation.height) }
                        .onEnded { _ in onDragEnded(); NSCursor.openHand.set() }
                )
                .accessibilityLabel("Drag to reorder")
            CheckCircle(done: item.completed) { state.setCompleted(item.id, !item.completed) }
            TextField("Untitled", text: $text, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...3)
                .focused($editing)
                .onSubmit { editing = false }
                .onExitCommand { text = item.title; editing = false }
                .onChange(of: text) { _, value in if value != item.title { state.rename(item.id, value) } }
                .onChange(of: editing) { _, now in if !now && item.isBlank { state.archive(item.id, announce: false) } }
                .accessibilityLabel("Task title")
                .padding(.leading, 2)
            Spacer(minLength: 6)
            HStack(spacing: 2) {
                Button { state.focusTask(item.id) } label: {
                    Label("Focus", systemImage: "scope").labelStyle(.titleAndIcon)
                }.buttonStyle(GhostButtonStyle()).disabled(item.isBlank)
                    .help("Make this your current focus")
                Button { state.setLater(item.id, !item.later) } label: { Image(systemName: item.later ? "sun.max" : "moon") }
                    .buttonStyle(GhostButtonStyle()).help(item.later ? "Move to Today" : "Move to Later")
                    .accessibilityLabel(item.later ? "Move \(item.title) to Today" : "Move \(item.title) to Later")
                Button { state.archive(item.id) } label: { Image(systemName: "archivebox") }
                    .buttonStyle(GhostButtonStyle()).help("Archive")
                    .accessibilityLabel("Archive \(item.title)")
            }
            .opacity(hovering || editing ? 1 : 0)
            .allowsHitTesting(hovering || editing)
        }
        .padding(.leading, 2).padding(.trailing, 6).padding(.vertical, 3)
        .background {
            if isDragging {
                RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(ink.opacity(0.12)))
                    .shadow(color: .black.opacity(0.16), radius: 12, y: 6)
            } else {
                RoundedRectangle(cornerRadius: 7).fill(ink.opacity(hovering && !anyDragging ? 0.045 : 0))
            }
        }
        .scaleEffect(isDragging ? 1.015 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onAppear { text = item.title }
        .onChange(of: item.title) { _, value in if value != text { text = value } }
        .contextMenu {
            Button("Focus") { state.focusTask(item.id) }.disabled(item.isBlank)
            Button("Rename") { editing = true }
            Button(item.completed ? "Mark as not done" : "Mark as done") { state.setCompleted(item.id, !item.completed) }
            Button(item.later ? "Move to Today" : "Move to Later") { state.setLater(item.id, !item.later) }
            Divider()
            Button("Move to top") { state.moveToTop(item.id) }.disabled(isFirst)
            Button("Move up") { state.move(item.id, by: -1) }.disabled(isFirst)
            Button("Move down") { state.move(item.id, by: 1) }.disabled(isLast)
            Divider()
            Button("Archive") { state.archive(item.id) }
        }
    }
}

/// Compact row used in the Completed / Archived groups.
struct SecondaryRow<Actions: View>: View {
    let title: String
    var leading: AnyView? = nil
    @ViewBuilder let actions: () -> Actions
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 6) {
            if let leading { leading } else { Color.clear.frame(width: 23, height: 23) }
            Text(title.isEmpty ? "Untitled" : title).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.secondary).italic(title.isEmpty)
            Spacer(minLength: 6)
            HStack(spacing: 2) { actions() }.opacity(hovering ? 1 : 0).allowsHitTesting(hovering)
        }
        .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 2)
        .background(ink.opacity(hovering ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Collapsible group header: chevron + label + count.
struct GroupHeader: View {
    let title: String
    let count: Int
    @Binding var expanded: Bool
    @State private var hovering = false
    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text(title).font(.system(size: 11, weight: .semibold))
                Text("\(count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
            }
            .foregroundStyle(hovering ? ink : Color.secondary)
            .padding(.horizontal, 6).frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }.pointer()
    }
}

// MARK: - Main window

struct SettingsView: View {
    @ObservedObject var state: FocusState
    @SwiftUI.FocusState var editing: Bool
    @SwiftUI.FocusState private var addingTask: Bool
    @SwiftUI.FocusState private var addingLater: Bool
    @State private var laterDraft = ""
    @State private var showArchived = false
    @State private var showCompleted = false
    @State private var dragID: UUID?
    @State private var dragY: CGFloat = 0
    @State private var rowHeights: [UUID: CGFloat] = [:]
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var cardFrames: [Bool: CGRect] = [:]
    @State private var dragFrames: [UUID: CGRect] = [:]
    @State private var dragCards: [Bool: CGRect] = [:]
    @State private var mouseUpMonitor: Any?
    private let rowSpacing: CGFloat = 1
    private var surface: Color { Color(nsColor: .controlBackgroundColor) }
    private var canFocus: Bool { state.hasTask && !state.completed }
    private var statusText: String {
        if state.completed { return "Done · reminders paused" }
        return "Reminding every \(state.interval) min"
    }
    private var statusLive: Bool { state.hasTask && !state.completed }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Daylight").font(.system(size: 20, weight: .semibold))
                        Spacer()
                        Text(Date.now, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    focusSection
                    taskList
                    settingsSection
                }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 24)
            }
            .frame(height: min(600, (NSScreen.main?.visibleFrame.height ?? 800) - 140))
            .overlay(alignment: .bottom) { toastView }
            Divider()
            HStack(spacing: 8) {
                Button("Preview reminder") { state.onPreview?() }
                    .buttonStyle(GhostButtonStyle()).disabled(!canFocus)
                    .help("Show the reminder bubble now")
                Spacer()
                Button {
                    editing = false
                    state.onStartFocusing?()
                } label: {
                    HStack(spacing: 8) {
                        Text("Start focusing")
                        Text("⌘↩").font(.system(size: 11, weight: .medium)).opacity(0.55)
                    }
                }
                .buttonStyle(FocusButtonStyle()).disabled(!canFocus).pointer()
                .keyboardShortcut(.return, modifiers: .command)
            }.padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .foregroundStyle(ink).tint(.gray)
        .background {
            // ⌘N: jump to the new-task field.
            Button("") { addingTask = true }.keyboardShortcut("n", modifiers: .command).hidden()
        }
    }

    // Current focus card
    @ViewBuilder private var focusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Current focus")
            if let id = state.tasks.activeID {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        CheckCircle(done: state.completed, size: 18) { state.setCompleted(id, !state.completed) }
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
                        TextField("What matters most right now?", text: Binding(get: { state.task }, set: { state.task = String($0.prefix(180)) }), axis: .vertical)
                            .font(.system(size: 17, weight: .medium)).lineLimit(1...4)
                            .textFieldStyle(.plain).focused($editing)
                            .strikethrough(state.completed && !editing)
                            .onSubmit { editing = false }
                            .accessibilityLabel("Current focus")
                    }
                    HStack(spacing: 6) {
                        Circle().fill(statusLive ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                        Text(statusText).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        Spacer()
                        Button { state.archive(id) } label: { Image(systemName: "archivebox") }
                            .buttonStyle(GhostButtonStyle()).help("Archive")
                            .accessibilityLabel("Archive current focus")
                        Button(state.completed ? "Reopen" : "Mark done") { state.setCompleted(id, !state.completed) }
                            .buttonStyle(GhostButtonStyle(prominent: true))
                    }.padding(.leading, 30)
                }
                .padding(.horizontal, 12).padding(.vertical, 12)
                .background(surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ink.opacity(editing ? 0.28 : 0.09), lineWidth: 1))
                .animation(.easeOut(duration: 0.12), value: editing)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "scope").foregroundStyle(.tertiary)
                    Text(state.openTasks.isEmpty ? "Add a task below to get started." : "Nothing in focus. Hover a task and choose Focus.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10).strokeBorder(ink.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
        }
    }

    // Today + Later + Completed + Archived
    private var taskList: some View {
        VStack(alignment: .leading, spacing: 6) {
            taskSection("Today", state.todayTasks, later: false)
            taskSection("Later", state.laterTasks, later: true).padding(.top, 12)

            if !state.completedTasks.isEmpty {
                GroupHeader(title: "Completed", count: state.completedTasks.count, expanded: $showCompleted).padding(.top, 6)
                if showCompleted {
                    VStack(spacing: 1) {
                        ForEach(state.completedTasks) { item in
                            SecondaryRow(title: item.title, leading: AnyView(CheckCircle(done: true) { state.setCompleted(item.id, false) })) {
                                Button { state.archive(item.id) } label: { Image(systemName: "archivebox") }
                                    .buttonStyle(GhostButtonStyle()).help("Archive")
                            }
                        }
                    }.transition(.opacity)
                }
            }
            if !state.archivedTasks.isEmpty {
                GroupHeader(title: "Archived", count: state.archivedTasks.count, expanded: $showArchived)
                if showArchived {
                    VStack(spacing: 1) {
                        ForEach(state.archivedTasks) { item in
                            SecondaryRow(title: item.title) {
                                Button("Restore") { state.restore(item.id) }.buttonStyle(GhostButtonStyle())
                                Button("Delete") { state.deleteForever(item.id) }
                                    .buttonStyle(GhostButtonStyle(destructive: true)).help("Delete permanently")
                            }
                        }
                    }.transition(.opacity)
                }
            }
        }
    }

    private func taskSection(_ title: String, _ list: [DailyTask], later: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                sectionLabel(title)
                Text("\(list.count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
            }
            VStack(spacing: rowSpacing) {
                ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                    TaskRow(state: state, item: item, isFirst: index == 0, isLast: index == list.count - 1,
                            isDragging: dragID == item.id, anyDragging: dragID != nil,
                            onDragChanged: { dragChanged(item.id, $0) }, onDragEnded: dragEnded)
                        .background(GeometryReader { g in
                            Color.clear
                                .preference(key: RowHeightsKey.self, value: [item.id: g.size.height])
                                .preference(key: RowFramesKey.self, value: [item.id: g.frame(in: .global)])
                        })
                        .offset(y: rowOffset(item.id, list))
                        .zIndex(dragID == item.id ? 1 : 0)
                        .animation(dragID == item.id ? nil : .easeOut(duration: 0.16), value: dragTarget(list))
                        .transition(.opacity)
                }
                newTaskRow(later: later)
            }
            .padding(4)
            .background(surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ink.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ink.opacity(crossDrop?.later == later ? 0.25 : 0)))
            .overlay(alignment: .topLeading) {
                if let drop = crossDrop, drop.later == later {
                    Capsule().fill(ink.opacity(0.55)).frame(height: 2).frame(maxWidth: .infinity)
                        .padding(.horizontal, 10)
                        .offset(y: insertionY(list, drop.index, later) - 1)
                        .allowsHitTesting(false)
                }
            }
            .background(GeometryReader { g in Color.clear.preference(key: CardFramesKey.self, value: [later: g.frame(in: .global)]) })
            .onPreferenceChange(RowHeightsKey.self) { rowHeights.merge($0) { $1 } }
            .onPreferenceChange(RowFramesKey.self) { rowFrames.merge($0) { $1 } }
            .onPreferenceChange(CardFramesKey.self) { cardFrames.merge($0) { $1 } }
            .animation(.easeOut(duration: 0.15), value: list.map(\.id))
            .onAppear {
                // Safety net: any mouse-up ends a drag, even if the gesture got cancelled.
                if mouseUpMonitor == nil {
                    mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
                        if dragID != nil { DispatchQueue.main.async { dragEnded() } }
                        return event
                    }
                }
            }
        }
        .zIndex(list.contains { $0.id == dragID } ? 1 : 0)
    }

    // Drag-to-reorder. The model is NOT touched mid-drag (reordering views under an
    // active gesture is what made rows get stuck). The dragged row follows the cursor,
    // neighbours slide out of the way visually, and the move is committed once on release.
    private func height(_ id: UUID) -> CGFloat { (rowHeights[id] ?? 32) + rowSpacing }
    private func dragTarget(_ open: [DailyTask]) -> Int {
        guard let id = dragID, let from = open.firstIndex(where: { $0.id == id }) else { return -1 }
        var target = from, travelled: CGFloat = 0
        if dragY > 0 {
            for k in (from + 1)..<max(from + 1, open.count) {
                let h = height(open[k].id)
                if dragY > travelled + h / 2 { target = k; travelled += h } else { break }
            }
        } else if dragY < 0 {
            for k in stride(from: from - 1, through: 0, by: -1) {
                let h = height(open[k].id)
                if -dragY > travelled + h / 2 { target = k; travelled += h } else { break }
            }
        }
        return target
    }
    /// Where a drag would land in the other section, or nil while it stays within its own.
    private var crossDrop: (later: Bool, index: Int)? {
        guard let id = dragID, let row = dragFrames[id], let today = dragCards[false], let laterCard = dragCards[true] else { return nil }
        let y = row.midY + dragY
        let toLater = y > (today.maxY + laterCard.minY) / 2
        guard toLater != state.laterTasks.contains(where: { $0.id == id }) else { return nil }
        let list = toLater ? state.laterTasks : state.todayTasks
        return (toLater, list.filter { (dragFrames[$0.id]?.midY ?? .infinity) < y }.count)
    }
    private func insertionY(_ list: [DailyTask], _ index: Int, _ later: Bool) -> CGFloat {
        guard let card = dragCards[later] else { return 4 }
        if index < list.count, let f = dragFrames[list[index].id] { return f.minY - card.minY }
        if let last = list.last, let f = dragFrames[last.id] { return f.maxY - card.minY }
        return 4
    }
    private func rowOffset(_ id: UUID, _ open: [DailyTask]) -> CGFloat {
        guard let dragged = dragID, let from = open.firstIndex(where: { $0.id == dragged }) else { return 0 }
        if id == dragged { return dragY }
        if crossDrop != nil { return 0 }
        guard let k = open.firstIndex(where: { $0.id == id }) else { return 0 }
        let target = dragTarget(open)
        if target > from, k > from, k <= target { return -height(dragged) }
        if target < from, k >= target, k < from { return height(dragged) }
        return 0
    }
    private func dragChanged(_ id: UUID, _ translation: CGFloat) {
        // Snapshot layout at lift-off: live frames include the drag offsets, which would feed back into the drop math.
        if dragID == nil { dragID = id; dragFrames = rowFrames; dragCards = cardFrames }
        guard dragID == id else { return }
        // Keep the lifted row between the top of Today and the bottom of Later.
        guard let row = dragFrames[id], let top = dragCards[false]?.minY, let bottom = dragCards[true]?.maxY else { dragY = translation; return }
        dragY = min(bottom - row.maxY, max(top - row.minY, translation))
    }
    private func dragEnded() {
        guard let id = dragID else { return }
        let target = dragTarget(state.section(of: id))
        let drop = crossDrop
        withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
            if let drop { state.move(id, toLater: drop.later, at: drop.index) } else { state.place(id, at: target) }
            dragID = nil
            dragY = 0
        }
    }

    private func newTaskRow(later: Bool) -> some View {
        let draft = later ? $laterDraft : $state.draft
        let focused = later ? $addingLater : $addingTask
        let isFocused = later ? addingLater : addingTask
        return HStack(spacing: 6) {
            Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                .frame(width: 14 + 6 + 23, alignment: .center)
            TextField(later ? "Add for later" : "New task", text: draft)
                .textFieldStyle(.plain).font(.system(size: 13))
                .focused(focused)
                .onChange(of: draft.wrappedValue) { _, value in if value.count > 180 { draft.wrappedValue = String(value.prefix(180)) } }
                .onSubmit { addTask(later: later); focused.wrappedValue = true }
                .onExitCommand { draft.wrappedValue = ""; focused.wrappedValue = false }
                .accessibilityLabel(later ? "New task for later" : "New task")
            if !later && !isFocused && draft.wrappedValue.isEmpty {
                Text("⌘N").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
            } else if !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("↩ to add").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 2).padding(.trailing, 10).frame(minHeight: 32)
        .contentShape(Rectangle())
        .onTapGesture { focused.wrappedValue = true }
    }

    // Reminder + ghost settings
    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Settings")
            VStack(spacing: 0) {
                settingsRow("Remind me every") {
                    Stepper(value: $state.interval, in: 1...180) {
                        Text("\(state.interval) min").monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                    }.fixedSize().accessibilityLabel("Reminder frequency in minutes")
                }
                rowDivider
                settingsRow("Show reminder for") {
                    Stepper(value: $state.duration, in: 3...30) {
                        Text("\(state.duration) sec").monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                    }.fixedSize().accessibilityLabel("Message duration in seconds")
                }
                rowDivider
                settingsRow("Reminder background") {
                    Slider(value: $state.backgroundOpacity, in: 0...0.7).frame(width: 100).accessibilityLabel("Message background opacity")
                    Text("\(Int(state.backgroundOpacity * 100))%").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                }
                rowDivider
                settingsRow("Ghost position") {
                    Button("Reset") { NotificationCenter.default.post(name: .init("ResetReminder"), object: nil) }
                        .buttonStyle(GhostButtonStyle()).help("Move the ghost back to its default spot")
                }
            }
            .background(surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ink.opacity(0.07)))
        }
    }

    @ViewBuilder private var toastView: some View {
        if let toast = state.toast {
            HStack(spacing: 10) {
                Text(toast.verb).font(.system(size: 12, weight: .semibold))
                Text(toast.title).font(.system(size: 12)).lineLimit(1).truncationMode(.middle).opacity(0.75)
                Spacer(minLength: 4)
                Button("Undo") { state.undoToast() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).pointer()
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            .padding(.horizontal, 14).frame(height: 36)
            .background(ink.opacity(0.92), in: RoundedRectangle(cornerRadius: 9))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            .padding(.horizontal, 24).padding(.bottom, 14)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.id)
        }
    }

    private func addTask(later: Bool) {
        if later { state.addTask(laterDraft, later: true); laterDraft = "" }
        else { state.addTask(state.draft); state.draft = "" }
    }
    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 2)
    }
    private var rowDivider: some View { Divider().padding(.horizontal, 14) }
    private func settingsRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) { Text(title); Spacer(minLength: 12); content() }
            .font(.system(size: 13)).padding(.horizontal, 14).frame(height: 42)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let state = FocusState()
    var settings: NSWindow!
    var ghost: NSPanel!
    var bubble: NSPanel!
    var status: NSStatusItem!
    var timer: Timer?
    var nextReminder = Date.distantFuture
    var hideAt: Date?
    var positioning = false

    func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false; panel.isReleasedWhenClosed = false
        return panel
    }
    // Standard app + Edit menus so ⌘C/⌘V/⌘X/⌘A/⌘Z work in text fields.
    func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Daylight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 550), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        settings.title = "Daylight"
        settings.isOpaque = true; settings.backgroundColor = .windowBackgroundColor; settings.titlebarAppearsTransparent = true; settings.titleVisibility = .hidden
        let editor = NSHostingView(rootView: SettingsView(state: state))
        settings.contentView = editor
        settings.setContentSize(editor.fittingSize)
        settings.isReleasedWhenClosed = false; settings.center()
        ghost = makePanel(); ghost.delegate = self
        let avatar = GhostView(frame: NSRect(x: 0, y: 0, width: 76, height: 86))
        avatar.toolTip = "Click to open Daylight. Drag to move. Right-click for more."
        avatar.setAccessibilityElement(true); avatar.setAccessibilityLabel("Priority ghost")
        avatar.onClick = { [weak self] in self?.showSettings() }
        let ghostMenu = NSMenu()
        ghostMenu.addItem(withTitle: "Show priority", action: #selector(preview), keyEquivalent: "").target = self
        ghostMenu.addItem(withTitle: "Edit priority & timing…", action: #selector(openSettings), keyEquivalent: "").target = self
        avatar.menu = ghostMenu; ghost.contentView = avatar
        bubble = makePanel(); bubble.ignoresMouseEvents = true
        let content = TransparentHostingView(rootView: Reminder(state: state)); content.wantsLayer = true; content.layer?.backgroundColor = NSColor.clear.cgColor
        bubble.contentView = content
        state.onScheduleChange = { [weak self] in self?.reschedule() }
        state.onContentChange = { [weak self] in self?.hideMessage() }
        state.onPreview = { [weak self] in self?.preview() }
        state.onStartFocusing = { [weak self] in self?.startFocusing() }
        state.onVisibility = { [weak self] in
            guard let self else { return }
            if state.visible { ghost.orderFrontRegardless() } else { ghost.orderOut(nil); hideMessage() }
            reschedule()
        }
        NotificationCenter.default.addObserver(forName: .init("ResetReminder"), object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.layoutGhost(reset: true) } }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.layoutGhost() } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.state.checkDay(); self?.reschedule() } }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Daylight")
        let menu = NSMenu()
        menu.addItem(withTitle: "Edit priority & timing…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Show priority now", action: #selector(preview), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Daylight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = menu
        layoutGhost(); ghost.orderFrontRegardless(); reschedule()
        timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        RunLoop.main.add(timer!, forMode: .common)
        showSettings()
    }
    func reschedule() { hideMessage(); nextReminder = Date().addingTimeInterval(Double(state.interval) * 60) }
    func hideMessage() { bubble?.orderOut(nil); hideAt = nil }
    func tick() {
        state.checkDay()
        let now = Date()
        if let deadline = hideAt, now >= deadline { hideMessage() }
        if now >= nextReminder {
            nextReminder = now.addingTimeInterval(Double(state.interval) * 60)
            if state.visible && state.hasTask && !state.completed { showMessage() }
        }
    }
    @objc func preview() {
        state.checkDay()
        guard state.hasTask && !state.completed else { showSettings(); return }
        if !state.visible { state.toggleVisible() }
        showMessage()
        nextReminder = Date().addingTimeInterval(Double(state.interval) * 60)
    }
    func showMessage() {
        positionBubble(); bubble.orderFrontRegardless()
        hideAt = Date().addingTimeInterval(Double(state.duration))
    }
    func layoutGhost(reset: Bool = false) {
        guard ghost != nil else { return }
        var origin = ghost.frame.origin
        if ghost.frame.width == 0 || reset {
            if !reset, let p = UserDefaults.standard.array(forKey: "ghost.position") as? [Double], p.count == 2 { origin = NSPoint(x: p[0], y: p[1]) }
            else { let area = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame; origin = NSPoint(x: area.maxX - 100, y: area.minY + 100) }
        }
        let area = (NSScreen.screens.first { $0.frame.contains(NSPoint(x: origin.x + 38, y: origin.y + 43)) } ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        origin.x = max(area.minX, min(origin.x, area.maxX - 76)); origin.y = max(area.minY, min(origin.y, area.maxY - 86))
        positioning = true; ghost.setFrame(NSRect(origin: origin, size: NSSize(width: 76, height: 86)), display: true); positioning = false
        UserDefaults.standard.set([origin.x, origin.y], forKey: "ghost.position")
        if bubble != nil { positionBubble() }
    }
    func positionBubble() {
        let area = (ghost.screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let width = min(310.0, area.width - 24)
        let measurement = NSHostingView(rootView: Reminder(state: state).frame(width: width).fixedSize(horizontal: false, vertical: true))
        let height = min(max(76, ceil(measurement.fittingSize.height)), area.height - 24)
        var x = ghost.frame.minX - width - 8
        if x < area.minX + 12 { x = ghost.frame.maxX + 8 }
        x = max(area.minX + 12, min(x, area.maxX - width - 12))
        let y = max(area.minY + 12, min(ghost.frame.midY - height / 2, area.maxY - height - 12))
        bubble.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
    func windowDidMove(_ notification: Notification) { if !positioning { layoutGhost() } }
    @objc func openSettings() { showSettings() }
    /// Close the window, restart the interval, and show the reminder right away
    /// (after the window has finished hiding so nothing re-orders over the bubble).
    func startFocusing() {
        state.checkDay()
        guard state.hasTask && !state.completed else { return }
        settings.orderOut(nil)
        ghost.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.showMessage()
            self.nextReminder = Date().addingTimeInterval(Double(self.state.interval) * 60)
        }
    }
    func showSettings() {
        state.checkDay(); settings.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        // Don't drop the caret (and a selection) into the focus field on open; editing is opt-in.
        DispatchQueue.main.async { [weak self] in self?.settings.makeFirstResponder(nil) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
