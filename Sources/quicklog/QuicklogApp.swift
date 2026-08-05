import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Entry point

@main
enum QuicklogMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Accessory: no Dock icon, lives in the menu bar + hotkey only.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = JournalStore()
    private var panelController: PanelController!
    private var hotkey: Hotkey?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panelController = PanelController(store: store)
        setupMainMenu()
        setupStatusItem()
        registerHotkey()
        panelController.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelController.saveFrame()
        UserDefaults.standard.synchronize()
        hotkey = nil
    }

    // MARK: Main menu
    //
    // An accessory app shows no menu bar, but ⌘A/⌘C/⌘V/⌘X/⌘Z are dispatched
    // through `NSApp.mainMenu`. Without this menu those shortcuts do nothing in
    // the text field.

    private func setupMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Hide quicklog",
            action: #selector(hidePanel),
            keyEquivalent: "w"
        ).target = self
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit quicklog",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        // undo:/redo: are only declared by the responder chain at runtime.
        editMenu.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redo = editMenu.addItem(
            withTitle: "Redo",
            action: NSSelectorFromString("redo:"),
            keyEquivalent: "Z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    @objc private func hidePanel() {
        panelController.hide()
    }

    // MARK: Global hotkey — ⌘⇧Space

    private func registerHotkey() {
        hotkey = Hotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            // Hotkey callbacks are always delivered on the main queue.
            MainActor.assumeIsolated {
                self?.panelController.toggle()
            }
        }
        if hotkey == nil {
            NSLog("quicklog: failed to register global hotkey (already taken?)")
        }
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "square.and.pencil",
            accessibilityDescription: "quicklog"
        )
        let menu = NSMenu()
        menu.addItem(
            withTitle: "Open quicklog  ⌘⇧Space",
            action: #selector(openPanel),
            keyEquivalent: ""
        ).target = self
        menu.addItem(
            withTitle: "Reveal Storage Folder",
            action: #selector(revealStorage),
            keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func openPanel() {
        panelController.show()
    }

    @objc private func revealStorage() {
        NSWorkspace.shared.open(StorageManager.shared.directory)
    }
}

// MARK: - Carbon global hotkey

/// Thin wrapper over `RegisterEventHotKey`. Works without Accessibility permissions.
final class Hotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let action: () -> Void
    private static var registry: [UInt32: Hotkey] = [:]
    private static var nextID: UInt32 = 1

    private let id: UInt32

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        self.id = Hotkey.nextID
        Hotkey.nextID += 1

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                DispatchQueue.main.async {
                    Hotkey.registry[hotKeyID.id]?.action()
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )
        guard handlerStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x716C_6F67), id: id) // 'qlog'
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            if let eventHandler { RemoveEventHandler(eventHandler) }
            return nil
        }
        Hotkey.registry[id] = self
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        Hotkey.registry[id] = nil
    }
}
