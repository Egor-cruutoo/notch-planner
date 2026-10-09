import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox

enum IslandState: Equatable { case collapsed, expanded }
enum IslandPage: Equatable { case plan, homework, hwPlanner }
enum ListMode: Equatable { case tasks, notes }

struct Peek: Equatable {
    var icon: String
    var title: String
    var subtitle: String
    var color: Color
}

/// Состояние островка (геометрия, раскрыт/свёрнут, ввод и т. п.).
final class IslandModel: ObservableObject {
    @Published var state: IslandState = .collapsed
    @Published var peek: Peek?
    @Published var showSettings = false
    @Published var pinned = false
    @Published var quickText = ""
    @Published var focusToken = 0
    @Published var notchWidth: CGFloat = 190
    @Published var notchHeight: CGFloat = 32
    @Published var wingWidth: CGFloat = 150
    @Published var expandedSize = CGSize(width: 1120, height: 480)
    @Published var dayOffset = 0
    @Published var projectFilter: UUID?
    @Published var showDone = false
    @Published var toast: String?
    @Published var editingTaskID: UUID?
    @Published var launchAtLogin = false
    @Published var hoverCollapsed = false
    @Published var page: IslandPage = .plan
    @Published var hwCourseFilter: UUID?
    @Published var hwShowDone = false
    @Published var schedulingTaskID: UUID?
    @Published var plannerSelectedTask: UUID?
    @Published var plannerWeek = 0
    // Скриншоты
    @Published var importPhase: ImportPhase = .idle
    @Published var importEvents: [ImportedEvent] = []
    @Published var importImage: NSImage?
    @Published var importSourceText: String?
    @Published var aiBusy = false            // DeepSeek разбирает строку ввода
    @Published var undoAction: (() -> Void)?
    @Published var expandedAgendaID: String?
    // Шкала на главной
    @Published var timelineSelection: String?
    @Published var taskDrag: TaskDrag?
    var timelineGeo: TimelineGeo?
    // Чаты-заметки
    @Published var selectedChat: UUID?
    @Published var chatDraft = ""
    @Published var chatPending: [PendingAttachment] = []
    @Published var chatFocusToken = 0
    @Published var draggingChat: UUID?
    @Published var renamingChat: UUID?
    @Published var confirmDeleteChat: UUID?
    var chatComposerFocused = false
    var modalOpen = false
    var onPickFiles: () -> Void = {}
    @Published var dropZone = false         // тащат файл к островку — показываем, куда кинуть
    @Published var dropTargeted = false     // файл прямо над островком
    // Задачи/заметки в проекте
    @Published var listMode: ListMode = .tasks
    @Published var composerText = ""
    @Published var composerFocusToken = 0
    var onImportImage: (NSImage) -> Void = { _ in }
    var onImportText: (String) -> Void = { _ in }
    var onAddImported: () -> Void = {}
    var onCancelImport: () -> Void = {}   // мышь над свёрнутым островком (режим «по клику»)

    var pendingFocus = false
    var makeKey: () -> Void = {}
    private var toastWork: DispatchWorkItem?

    var collapsedSize: CGSize { CGSize(width: notchWidth + wingWidth * 2, height: notchHeight) }
    var peekSize: CGSize { CGSize(width: max(collapsedSize.width + 80, 460), height: notchHeight + 50) }
    var dropZoneSize: CGSize { CGSize(width: max(collapsedSize.width + 140, 560), height: notchHeight + 96) }
    var currentSize: CGSize {
        switch state {
        case .expanded: return expandedSize
        case .collapsed:
            if dropZone { return dropZoneSize }
            if peek != nil { return peekSize }
            // Лёгкий «вдох» под курсором — подсказка, что можно нажать.
            return hoverCollapsed ? CGSize(width: collapsedSize.width + 12, height: collapsedSize.height + 4) : collapsedSize
        }
    }

    func selectedDay(now: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: dayOffset, to: Calendar.current.startOfDay(for: now))!
    }

    func flash(_ text: String?, undo: (() -> Void)? = nil) {
        guard let text else { return }
        toast = text
        undoAction = undo
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.toast = nil
            self?.undoAction = nil
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (undo != nil ? 8 : text.count > 50 ? 5 : 2.6), execute: work)
    }

    func requestFocus() {
        pendingFocus = true
        focusToken += 1
    }
}

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // Иначе macOS сдвигает окно под строку меню, а нам нужно ровно к вырезу.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// У приложения без Dock нет меню «Правка», а именно оно превращает ⌘V/⌘C/… в команды.
    /// Поэтому ловим сочетания здесь — по физическим клавишам, чтобы работало и в русской раскладке.
    static var pasteHandler: (() -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, IslandPanel.editAction(for: event) == #selector(NSText.paste(_:)),
           let handler = IslandPanel.pasteHandler, handler() {
            return true
        }
        if event.type == .keyDown, let action = IslandPanel.editAction(for: event),
           let responder = firstResponder, responder.tryToPerform(action, with: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    static func editAction(for event: NSEvent) -> Selector? {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == .command || flags == [.command, .shift] else { return nil }
        let shift = flags.contains(.shift)
        switch Int(event.keyCode) {
        case kVK_ANSI_V: return shift ? nil : #selector(NSText.paste(_:))
        case kVK_ANSI_C: return shift ? nil : #selector(NSText.copy(_:))
        case kVK_ANSI_X: return shift ? nil : #selector(NSText.cut(_:))
        case kVK_ANSI_A: return shift ? nil : #selector(NSText.selectAll(_:))
        case kVK_ANSI_Z: return shift ? Selector(("redo:")) : Selector(("undo:"))
        default: return nil
        }
    }
}

final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Окно-островок у выреза: следит за мышью, раскрывает/сворачивает, показывает «живые» уведомления.
final class IslandController {
    let model: IslandModel
    let store: Store
    let panel: IslandPanel

    private var pollTimer: Timer?
    private var liveTimer: Timer?
    private var peekWork: DispatchWorkItem?
    private var hoverSince: Date?
    private var leaveSince: Date?
    private var menuTracking = false
    private var openedByHotKey = false
    private var mouseWasInside = false
    private var screenFrame: NSRect = .zero
    private var lastCurrentID: String?
    private var announced = Set<String>()
    private var liveTicks = 0
    private var bag = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private var externalDrag = false
    private let margin: CGFloat = 40   // место под тень

    init(model: IslandModel, store: Store) {
        self.model = model
        self.store = store
        panel = IslandPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)

        let host = IslandHostingView(rootView: IslandRootView(model: model, store: store))
        host.sizingOptions = []
        panel.contentView = host

        model.makeKey = { [weak self] in self?.panel.makeKey() }
        model.onImportImage = { [weak self] image in self?.importImage(image) }
        model.onImportText = { [weak self] text in self?.importText(text) }
        model.onAddImported = { [weak self] in self?.addImported() }
        model.onCancelImport = { [weak self] in self?.cancelImport() }
        model.onPickFiles = { [weak self] in self?.pickFiles() }
        IslandPanel.pasteHandler = { [weak self] in self?.pasteIntoChat() ?? false }

        layout()
        panel.orderFrontRegardless()

        let poll = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.pollMouse() }
        RunLoop.main.add(poll, forMode: .common)
        pollTimer = poll

        let live = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.liveTick() }
        RunLoop.main.add(live, forMode: .common)
        liveTimer = live
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.liveTick() }

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.layout()
        })
        observers.append(nc.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.menuTracking = true
        })
        observers.append(nc.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.menuTracking = false
            self?.leaveSince = nil
        })
        observers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            self?.panelResignedKey()
        })
        let wnc = NSWorkspace.shared.notificationCenter
        observers.append(wnc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.layout()
            self?.liveTick()
        })
        observers.append(wnc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.panel.orderFrontRegardless()
        })

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                self.escape()
                return nil
            }
            return event
        }

        // Клик по свёрнутому островку — раскрыть.
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.window === self.panel, self.model.state == .collapsed else { return event }
            self.expand(focus: false)
            return nil
        }

        // Тащат файл (скриншот) из другого приложения — островок покажет, куда его кинуть.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            self?.dragChangeCount = NSPasteboard(name: .drag).changeCount
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            guard let self, !self.externalDrag else { return }
            if NSPasteboard(name: .drag).changeCount != self.dragChangeCount { self.externalDrag = true }
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            guard let self else { return }
            self.externalDrag = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if !self.externalDrag && self.model.dropZone { self.model.dropZone = false }
            }
        }

        // Клик мимо раскрытого островка — свернуть.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.model.state == .expanded, !self.model.pinned, !self.menuTracking else { return }
            if !self.contains(self.rect(for: self.model.expandedSize), NSEvent.mouseLocation) { self.collapse() }
        }

        store.$data.map(\.settings.wideCollapsed).removeDuplicates().dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.layout() } }
            .store(in: &bag)
    }

    // MARK: - Геометрия

    func layout() {
        let screens = NSScreen.screens
        guard let screen = screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? screens.first else { return }
        let f = screen.frame
        screenFrame = f

        var notchW: CGFloat = 0
        var barH = f.maxY - screen.visibleFrame.maxY
        if screen.safeAreaInsets.top > 0 {
            barH = screen.safeAreaInsets.top
            if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
                notchW = f.width - l.width - r.width
            }
        }
        if barH < 22 { barH = 24 }

        model.notchWidth = notchW.rounded()
        model.notchHeight = barH.rounded()
        model.wingWidth = store.data.settings.wideCollapsed ? 290 : 150
        let w = min(f.width - 48, 1360).rounded()
        let h = min(max(f.height * 0.54, 460), 620).rounded()
        model.expandedSize = CGSize(width: w, height: h)

        let winW = w + margin * 2
        let winH = h + margin
        panel.setFrame(NSRect(x: (f.midX - winW / 2).rounded(), y: f.maxY - winH, width: winW, height: winH), display: true)
    }

    private func rect(for size: CGSize) -> NSRect {
        NSRect(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height,
               width: size.width, height: size.height)
    }

    private func contains(_ r: NSRect, _ p: NSPoint) -> Bool {
        p.x >= r.minX && p.x <= r.maxX && p.y >= r.minY && p.y <= r.maxY + 2
    }

    private func setInteractive(_ on: Bool) {
        if panel.ignoresMouseEvents == on { panel.ignoresMouseEvents = !on }
    }

    // MARK: - Мышь

    private var shouldStayOpen: Bool {
        model.pinned || !model.quickText.isEmpty || !model.composerText.isEmpty || model.editingTaskID != nil || model.aiBusy
            || !model.chatDraft.isEmpty || !model.chatPending.isEmpty || model.modalOpen || model.taskDrag != nil
            || model.renamingChat != nil
            || model.importPhase != .idle || (openedByHotKey && !mouseWasInside)
    }

    private func pollMouse() {
        let p = NSEvent.mouseLocation
        let now = Date()
        switch model.state {
        case .collapsed:
            // Файл тащат к вырезу — раскрываем «зону сброса».
            let near = contains(rect(for: CGSize(width: model.collapsedSize.width + 300, height: model.notchHeight + 140)), p)
            let wantZone = externalDrag && near
            if model.dropZone != wantZone { model.dropZone = wantZone }
            let inside = contains(rect(for: model.currentSize).insetBy(dx: -2, dy: 0), p) || wantZone
            setInteractive(inside)
            let openOnHover = store.data.settings.openOnHover && !externalDrag
            let breathe = inside && !openOnHover && !wantZone
            if model.hoverCollapsed != breathe { model.hoverCollapsed = breathe }
            if inside && openOnHover {
                if let since = hoverSince {
                    if now.timeIntervalSince(since) >= 0.15 { expand(focus: false) }
                } else {
                    hoverSince = now
                }
            } else {
                hoverSince = nil
            }
        case .expanded:
            let inside = contains(rect(for: model.expandedSize), p)
            setInteractive(inside || menuTracking)
            if inside { mouseWasInside = true }
            let settings = store.data.settings
            if inside || menuTracking || shouldStayOpen || !settings.closeOnLeave {
                leaveSince = nil
            } else if let since = leaveSince {
                if now.timeIntervalSince(since) >= (settings.openOnHover ? 0.35 : 0.6) { collapse() }
            } else {
                leaveSince = now
            }
        }
    }

    // MARK: - Раскрытие / сворачивание

    func expand(focus: Bool) {
        hoverSince = nil
        leaveSince = nil
        mouseWasInside = false
        model.hoverCollapsed = false
        peekWork?.cancel()
        model.peek = nil
        store.now = Date()
        if model.state != .expanded { model.state = .expanded }
        setInteractive(true)
        if focus {
            panel.makeKeyAndOrderFront(nil)
            model.requestFocus()
        }
    }

    func collapse() {
        guard model.state == .expanded else { return }
        hoverSince = nil
        leaveSince = nil
        openedByHotKey = false
        model.editingTaskID = nil
        model.showSettings = false
        model.state = .collapsed
        setInteractive(false)
        if panel.isKeyWindow {
            // Возвращаем клавиатуру приложению, в котором работали до островка.
            panel.makeFirstResponder(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.model.state == .collapsed, self.panel.isKeyWindow else { return }
                self.panel.orderOut(nil)
                self.panel.orderFrontRegardless()
            }
        }
    }

    func openFromOutside() {
        openedByHotKey = true
        expand(focus: true)
    }

    func toggleFromHotKey() {
        if model.state == .expanded && panel.isKeyWindow {
            collapse()
        } else {
            openFromOutside()
        }
    }

    /// 📎 в чате — выбрать файлы.
    func pickFiles() {
        model.modalOpen = true
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Прикрепить"
        panel.level = NSWindow.Level(rawValue: self.panel.level.rawValue + 1)
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self else { return }
            self.model.modalOpen = false
            if response == .OK {
                self.model.chatPending += panel.urls.map { PendingAttachment(file: $0, name: $0.lastPathComponent) }
            }
            self.panel.makeKeyAndOrderFront(nil)
            self.model.chatFocusToken += 1
        }
    }

    /// ⌘V в поле чата: файлы и картинки из буфера становятся вложениями, обычный текст вставляется как текст.
    func pasteIntoChat() -> Bool {
        guard model.chatComposerFocused else { return false }
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            model.chatPending += urls.map { PendingAttachment(file: $0, name: $0.lastPathComponent) }
            return true
        }
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg")]
        if pb.availableType(from: imageTypes) != nil, let image = NSImage(pasteboard: pb) {
            model.chatPending.append(PendingAttachment(image: image, name: "Изображение.png"))
            return true
        }
        return false
    }

    func openSettings() {
        openFromOutside()
        model.showSettings = true
    }

    private func panelResignedKey() {
        guard model.state == .expanded, !model.pinned, !model.modalOpen else { return }
        if !contains(rect(for: model.expandedSize), NSEvent.mouseLocation) { collapse() }
    }

    private func escape() {
        if model.editingTaskID != nil { model.editingTaskID = nil; return }
        if model.timelineSelection != nil { model.timelineSelection = nil; return }
        if model.confirmDeleteChat != nil { model.confirmDeleteChat = nil; return }
        if !model.chatPending.isEmpty && model.chatDraft.isEmpty { model.chatPending = []; return }
        if model.importPhase != .idle { cancelImport(); return }
        if !model.composerText.isEmpty { model.composerText = ""; return }
        if model.schedulingTaskID != nil { model.schedulingTaskID = nil; return }
        if model.page == .hwPlanner, model.plannerSelectedTask != nil { model.plannerSelectedTask = nil; return }
        if model.showSettings { model.showSettings = false; return }
        if !model.quickText.isEmpty { model.quickText = ""; return }
        model.pinned = false
        collapse()
    }

    // MARK: - «Живые» уведомления: началось / скоро начнётся

    private func liveTick() {
        let now = Date()
        store.now = now
        liveTicks += 1
        if liveTicks % 20 == 0 { store.calendarService.refresh() }   // раз в ~5 минут подтягиваем с серверов
        if liveTicks % 240 == 0 { store.syncHomework() }              // дедлайны из LMS — раз в час

        store.rolloverStones(now: now)
        let current = store.currentItem(now: now)
        defer { lastCurrentID = current?.id }
        guard model.state == .collapsed else { return }

        if let cur = current, cur.id != lastCurrentID, now.timeIntervalSince(cur.start) < 120,
           !announced.contains("start-" + cur.id) {
            announced.insert("start-" + cur.id)
            showPeek(Peek(icon: "play.circle.fill", title: cur.title,
                          subtitle: "Началось · до \(Fmt.time(cur.end))", color: cur.color))
        } else if let next = store.nextItem(now: now), next.start.timeIntervalSince(now) <= 5 * 60,
                  !announced.contains("soon-" + next.id) {
            announced.insert("soon-" + next.id)
            showPeek(Peek(icon: "bell.fill", title: next.title,
                          subtitle: "Через \(Fmt.duration(seconds: next.start.timeIntervalSince(now))) · в \(Fmt.time(next.start))",
                          color: next.color))
        }
    }

    private func showPeek(_ peek: Peek) {
        model.peek = peek
        peekWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.model.peek = nil }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: work)
    }
}

// MARK: - Глобальная горячая клавиша (Carbon, не требует доступа к «Универсальному доступу»)

final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static var actions: [UInt32: () -> Void] = [:]

    init(id: UInt32 = 1, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        GlobalHotKey.actions[id] = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { GlobalHotKey.actions[id]?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        let hotKeyID = EventHotKeyID(signature: OSType(0x4F53_544B), id: id)   // 'OSTK'
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
