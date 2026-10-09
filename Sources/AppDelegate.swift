import AppKit
import Combine
import ServiceManagement
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let openNotification = Notification.Name("local.ostrovok.open")

    private var store: Store!
    private var model: IslandModel!
    private var controller: IslandController!
    private var statusItem: NSStatusItem?
    private var hotKey: GlobalHotKey?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Snapshot.run(outputDir: args[i + 1])
            NSApp.terminate(nil)
            return
        }

        // Уже запущен — просто просим открыть островок у работающего экземпляра.
        if let bid = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bid)
               .contains(where: { $0.processIdentifier != getpid() }) {
            DistributedNotificationCenter.default().postNotificationName(AppDelegate.openNotification, object: nil,
                                                                         userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }

        store = Store()
        model = IslandModel()
        model.launchAtLogin = SMAppService.mainApp.status == .enabled
        controller = IslandController(model: model, store: store)

        hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            self?.controller.toggleFromHotKey()
        }

        DistributedNotificationCenter.default().addObserver(forName: AppDelegate.openNotification, object: nil, queue: .main) { [weak self] _ in
            self?.controller.openFromOutside()
        }

        setupStatusItem()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.store.autoPickWriteCalendar()
            self?.store.syncCalendarNow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.store.syncHomework() }
        store.$data.map(\.settings.showMenuBarIcon).removeDuplicates()
            .sink { [weak self] visible in self?.statusItem?.isVisible = visible }
            .store(in: &bag)
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.saveNow()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Островок") {
            image.isTemplate = true
            item.button?.image = image
        }
        let menu = NSMenu()
        let open = menu.addItem(withTitle: "Открыть островок", action: #selector(openIsland), keyEquivalent: "t")
        open.keyEquivalentModifierMask = [.control, .option]
        open.target = self
        menu.addItem(withTitle: "Настройки…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Выйти", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        item.isVisible = store.data.settings.showMenuBarIcon
        statusItem = item
    }

    @objc private func openIsland() { controller.openFromOutside() }
    @objc private func openSettings() { controller.openSettings() }
    @objc private func quit() {
        store.saveNow()
        NSApp.terminate(nil)
    }
}
