import AppKit
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Entry point

@main
enum QuicklogMain {
    @MainActor
    static func main() {
        // Only one instance may ever run — a second one would give a duplicate
        // menu-bar icon and two processes writing the same files.
        guard SingleInstance.acquire() else {
            SingleInstance.askRunningInstanceToShow()
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Accessory: no Dock icon, lives in the menu bar + hotkey only.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

// MARK: - Single instance

/// Enforced with an advisory lock on a file in the storage directory. The kernel
/// drops the lock when the process dies, so a crash cannot leave it stuck — and
/// unlike a bundle-identifier check it also covers running the bare binary.
///
/// Best effort by design: if the lock cannot be taken *for any reason other than
/// another instance holding it*, the app starts anyway and logs why. A duplicate
/// menu-bar icon is a bad outcome; an app that silently refuses to launch — no
/// window, no icon, no message — is a worse one.
enum SingleInstance {
    /// Sent by a second launch so the instance that owns the lock surfaces.
    static let showNotification = Notification.Name("com.bigbrain.quicklog.show")

    private static var fd: Int32 = -1

    static func acquire() -> Bool {
        let path = StorageManager.shared.directory
            .appendingPathComponent(".instance.lock").path
        fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            NSLog("quicklog: can't open the instance lock (%s) — starting without it",
                  strerror(errno))
            return true
        }

        // `flock` is interruptible even with LOCK_NB, and a signal is not
        // contention.
        var attempts = 0
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR, attempts < 3 {
                attempts += 1
                continue
            }
            close(fd)
            fd = -1
            // Only these two mean "someone else holds it". Anything else — a
            // filesystem that doesn't implement flock, for instance — must not
            // end the launch.
            guard code == EWOULDBLOCK || code == EAGAIN else {
                NSLog("quicklog: instance lock unavailable (%s) — starting without it",
                      strerror(code))
                return true
            }
            return false
        }
        return true
    }

    static func askRunningInstanceToShow() {
        DistributedNotificationCenter.default().postNotificationName(
            showNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = JournalStore()
    private var panelController: PanelController!
    private var hotkey: Hotkey?
    private var statusItem: NSStatusItem?
    private var loginItem: NSMenuItem?
    /// False when `⌘⇧Space` was already taken — surfaced in the menu bar.
    private var hotkeyRegistered = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        panelController = PanelController(store: store)
        setupMainMenu()
        registerHotkey()
        setupStatusItem()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(openPanel),
            name: SingleInstance.showNotification,
            object: nil
        )
        panelController.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Quitting must not be the one exit that loses typing: every other way out
        // of the inline editor saves a changed body, so this one does too.
        if store.hasUnsavedEdit { store.endEdit() }
        panelController.saveFrame()
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
            withTitle: "Save Entry",
            action: #selector(saveEntry),
            keyEquivalent: "\r"
        ).target = self
        appMenu.addItem(.separator())
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

    /// ⌘↩ belongs to the menu rather than the Save buttons: the composer and the
    /// inline editor both have one, two SwiftUI buttons claiming the same
    /// shortcut makes which fires arbitrary, and swapping the shortcut between
    /// them as editing starts sends the hosting view into a layout loop.
    ///
    /// On a past day the composer is hidden but its draft is kept, and this saves
    /// it to today and jumps there — the past-day notice says as much while a
    /// draft is pending, so nothing is written out of sight.
    @objc private func saveEntry() {
        MainActor.assumeIsolated {
            guard panelController.isVisible else { return }
            if store.editingEntryID != nil {
                store.commitEdit()
            } else {
                store.saveDraft()
            }
        }
    }

    // MARK: Global hotkey — ⌘⇧Space

    private func registerHotkey() {
        hotkey = Hotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            // Hotkey callbacks are always delivered on the main queue.
            MainActor.assumeIsolated {
                self?.panelController.toggle()
            }
        }
        hotkeyRegistered = hotkey != nil
        if !hotkeyRegistered {
            NSLog("quicklog: failed to register global hotkey (already taken?)")
        }
    }

    // MARK: Launch at login

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            // Most likely cause: running the bare binary instead of the bundle,
            // or a copy macOS won't accept (not in /Applications).
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login item"
            alert.informativeText =
                "\(error.localizedDescription)\n\nRun `just install` so quicklog "
                + "lives in /Applications, then try again."
            alert.runModal()
        }
        refreshLoginItemState()
    }

    private func refreshLoginItemState() {
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // A failed hotkey registration is otherwise invisible — the app just
        // looks dead — so it changes the icon and adds an explanation.
        item.button?.image = NSImage(
            systemSymbolName: hotkeyRegistered
                ? "square.and.pencil"
                : "exclamationmark.triangle",
            accessibilityDescription: "quicklog"
        )
        item.button?.toolTip = hotkeyRegistered
            ? "quicklog — ⌘⇧Space"
            : "quicklog — ⌘⇧Space is taken by another app; use this menu"

        let menu = NSMenu()
        if !hotkeyRegistered {
            let warning = menu.addItem(
                withTitle: "⌘⇧Space unavailable — taken by another app",
                action: nil,
                keyEquivalent: ""
            )
            warning.isEnabled = false
            menu.addItem(.separator())
        }
        menu.addItem(
            withTitle: hotkeyRegistered ? "Open quicklog  ⌘⇧Space" : "Open quicklog",
            action: #selector(openPanel),
            keyEquivalent: ""
        ).target = self
        menu.addItem(
            withTitle: "Reveal Storage Folder",
            action: #selector(revealStorage),
            keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        let login = menu.addItem(
            withTitle: "Start at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        login.target = self
        loginItem = login
        refreshLoginItemState()
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
    /// Only ever one hotkey, so the Carbon callback doesn't need to work out
    /// which one fired.
    private static var current: Hotkey?

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ -> OSStatus in
                DispatchQueue.main.async { Hotkey.current?.action() }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )
        guard handlerStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x716C_6F67), id: 1) // 'qlog'
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
        Hotkey.current = self
    }

    /// Hygiene only — the one hotkey lives as long as the process. Carbon
    /// registrations are process-global, so releasing them explicitly is the
    /// correct shape even when nothing observes it.
    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if Hotkey.current === self { Hotkey.current = nil }
    }
}
