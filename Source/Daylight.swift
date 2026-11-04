import AppKit
import SwiftUI

struct DailyTask: Codable, Identifiable {
    var id = UUID()
    var title: String
    var completed = false
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
    func addTask(_ title: String) {
        checkDay()
        let cleaned = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
        guard !cleaned.isEmpty else { return }
        let item = DailyTask(title: cleaned)
        tasks.items.append(item)
        if tasks.activeID == nil { tasks.activeID = item.id; onScheduleChange?() }
        save()
    }
    func focusTask(_ id: UUID) {
        checkDay()
        guard let index = tasks.items.firstIndex(where: { $0.id == id }) else { return }
        tasks.items[index].completed = false
        tasks.activeID = id
        save(); onScheduleChange?()
    }
    @Published var interval = 15 { didSet { UserDefaults.standard.set(interval, forKey: "ghost.interval"); onScheduleChange?() } }
    @Published var duration = 7 { didSet { UserDefaults.standard.set(duration, forKey: "ghost.duration"); onScheduleChange?() } }
    @Published var backgroundOpacity = 0.15 { didSet { UserDefaults.standard.set(backgroundOpacity, forKey: "backgroundOpacity") } }
    @Published var visible = true
    @Published var day = ""
    var onScheduleChange: (() -> Void)?
    var onContentChange: (() -> Void)?
    var onPreview: (() -> Void)?
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
        if !tasks.items.contains(where: { $0.id == tasks.activeID }) { tasks.activeID = tasks.items.first?.id }
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

struct SettingsView: View {
    @ObservedObject var state: FocusState
    @SwiftUI.FocusState var editing: Bool
    private var surface: Color { Color(nsColor: .controlBackgroundColor) }
    private var statusText: String {
        if !state.hasTask { return "Add a priority to begin" }
        if state.completed { return "Completed · reminders paused" }
        if !state.visible { return "Ghost hidden · reminders paused" }
        return "A reminder every \(state.interval) minutes"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Tasks").font(.system(size: 22, weight: .semibold))
                    Spacer()
                    Text(Date.now, format: .dateTime.month(.abbreviated).day()).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if state.activeTask != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("Current focus")
                        priority
                    }
                }
                taskList
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Reminders")
                    VStack(spacing: 0) {
                        settingsRow("Frequency") {
                            Stepper(value: $state.interval, in: 1...180) {
                                Text("Every \(state.interval) min").monospacedDigit().frame(width: 105, alignment: .trailing)
                            }.fixedSize().accessibilityLabel("Reminder frequency in minutes")
                        }
                        rowDivider
                        settingsRow("Message duration") {
                            Stepper(value: $state.duration, in: 3...30) {
                                Text("\(state.duration) seconds").monospacedDigit().frame(width: 105, alignment: .trailing)
                            }.fixedSize().accessibilityLabel("Message duration in seconds")
                        }
                        rowDivider
                        settingsRow("Background opacity") {
                            Slider(value: $state.backgroundOpacity, in: 0...0.7).frame(width: 100).accessibilityLabel("Message background opacity")
                            Text("\(Int(state.backgroundOpacity * 100))%").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                        }
                    }.background(surface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ink.opacity(0.07)))
                }
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Desktop companion")
                    settingsRow("Show ghost") {
                        Toggle("Show ghost", isOn: Binding(get: { state.visible }, set: { value in if value != state.visible { state.toggleVisible() } }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }.background(surface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ink.opacity(0.07)))
                    HStack {
                        Text("Drag to move. Click for a reminder.").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset position") { NotificationCenter.default.post(name: .init("ResetReminder"), object: nil) }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                    }.padding(.horizontal, 2)
                }
            }.padding(24)
            }.frame(height: min(600, (NSScreen.main?.visibleFrame.height ?? 800) - 140))
            Divider()
            HStack(spacing: 12) {
                Button("Preview") { state.onPreview?() }.controlSize(.large).disabled(!state.hasTask || state.completed)
                Spacer()
                Button("Start focusing") {
                    editing = false
                    if !state.visible { state.toggleVisible() }
                    NSApp.keyWindow?.orderOut(nil)
                    state.onPreview?()
                }.buttonStyle(FocusButtonStyle()).disabled(!state.hasTask || state.completed)
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .foregroundStyle(ink).tint(.gray)
    }
    private var taskList: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Other tasks · \(state.tasks.items.filter { $0.id != state.tasks.activeID }.count)")
            VStack(spacing: 0) {
                ForEach(state.tasks.items.filter { $0.id != state.tasks.activeID }) { item in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.system(size: 13)).lineLimit(2)
                                .strikethrough(item.completed).foregroundStyle(item.completed ? .secondary : .primary)
                            if item.completed { Text("Completed").font(.system(size: 10)).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 8)
                        Button(item.completed ? "Focus again" : "Focus") { state.focusTask(item.id) }
                            .controlSize(.small)
                            .accessibilityLabel("Focus on \(item.title)")
                    }.padding(.horizontal, 14).padding(.vertical, 11)
                    rowDivider
                }
                HStack(spacing: 10) {
                    TextField("Add a task…", text: $state.draft)
                        .textFieldStyle(.plain).font(.system(size: 13))
                        .onChange(of: state.draft) { _, value in state.draft = String(value.prefix(180)) }
                        .onSubmit { addTask() }
                        .accessibilityLabel("New task")
                    Button("Add") { addTask() }.controlSize(.small)
                        .disabled(state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(14)
            }.background(surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ink.opacity(0.07)))
            Text("One task at a time. Choose Focus to switch your ghost’s reminder.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    private func addTask() {
        state.addTask(state.draft)
        state.draft = ""
    }
    private var priority: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("What matters most today?", text: Binding(get: { state.task }, set: { state.task = String($0.prefix(180)) }), axis: .vertical)
                .font(.system(size: 19, weight: .medium)).lineLimit(2...4)
                .textFieldStyle(.plain).focused($editing)
                .accessibilityLabel("Today's priority")
                .padding(16)
            HStack(spacing: 8) {
                Text(state.completed ? "Completed" : "Saved automatically")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(state.completed ? "Mark unfinished" : "Complete task") { state.completed.toggle() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).disabled(!state.hasTask)
            }.padding(.horizontal, 16).padding(.bottom, 13)
        }
        .background(surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ink.opacity(editing ? 0.35 : 0.10), lineWidth: 1))
        .overlay(alignment: .bottomLeading) {
            Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary).offset(y: 20)
        }
        .padding(.bottom, 15)
    }
    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 2)
    }
    private var rowDivider: some View { Divider().padding(.horizontal, 14) }
    private func settingsRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) { Text(title); Spacer(minLength: 12); content() }
            .font(.system(size: 13)).padding(.horizontal, 14).frame(height: 44)
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
        settings.isOpaque = true; settings.backgroundColor = .windowBackgroundColor; settings.titlebarAppearsTransparent = false
        let editor = NSHostingView(rootView: SettingsView(state: state))
        settings.contentView = editor
        settings.setContentSize(editor.fittingSize)
        settings.isReleasedWhenClosed = false; settings.center()
        ghost = makePanel(); ghost.delegate = self
        let avatar = GhostView(frame: NSRect(x: 0, y: 0, width: 76, height: 86))
        avatar.toolTip = "Click for today's priority. Drag to move. Right-click to edit."
        avatar.setAccessibilityElement(true); avatar.setAccessibilityLabel("Priority ghost")
        avatar.onClick = { [weak self] in self?.preview() }
        let ghostMenu = NSMenu()
        ghostMenu.addItem(withTitle: "Show priority", action: #selector(preview), keyEquivalent: "").target = self
        ghostMenu.addItem(withTitle: "Edit priority & timing…", action: #selector(openSettings), keyEquivalent: "").target = self
        ghostMenu.addItem(withTitle: "Hide ghost", action: #selector(toggleGhost), keyEquivalent: "").target = self
        avatar.menu = ghostMenu; ghost.contentView = avatar
        bubble = makePanel(); bubble.ignoresMouseEvents = true
        let content = TransparentHostingView(rootView: Reminder(state: state)); content.wantsLayer = true; content.layer?.backgroundColor = NSColor.clear.cgColor
        bubble.contentView = content
        state.onScheduleChange = { [weak self] in self?.reschedule() }
        state.onContentChange = { [weak self] in self?.hideMessage() }
        state.onPreview = { [weak self] in self?.preview() }
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
        menu.addItem(withTitle: "Show / hide ghost", action: #selector(toggleGhost), keyEquivalent: "").target = self
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
    @objc func toggleGhost() { state.toggleVisible() }
    func showSettings() { state.checkDay(); settings.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
