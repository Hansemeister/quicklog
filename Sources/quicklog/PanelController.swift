import AppKit
import SwiftUI

/// Floating panel that stays above other apps' windows and can take key focus.
final class QuicklogPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Esc hides the panel instead of closing/destroying it.
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private var panel: QuicklogPanel?
    private let store: JournalStore

    /// Persisted panel frame. `setFrameAutosaveName` alone only *saves*, so the
    /// frame is stored and restored explicitly.
    private let frameKey = "quicklog.panelFrame"

    init(store: JournalStore) {
        self.store = store
        super.init()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        store.reload()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        saveFrame()
        panel?.orderOut(nil)
    }

    // MARK: Frame persistence

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }
    func windowWillClose(_ notification: Notification) { saveFrame() }

    func saveFrame() {
        guard let panel, panel.isVisible else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: frameKey)
    }

    private func restoreFrame(_ panel: QuicklogPanel) {
        guard let saved = UserDefaults.standard.string(forKey: frameKey) else {
            panel.center()
            return
        }
        let rect = NSRectFromString(saved)
        // Ignore junk or a frame left on a screen that is no longer attached.
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(rect) }
        guard rect.width >= 300, rect.height >= 200, onScreen else {
            panel.center()
            return
        }
        panel.setFrame(rect, display: false)
    }

    // MARK: Setup

    private func makePanel() -> QuicklogPanel {
        let panel = QuicklogPanel(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "quicklog"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentMinSize = NSSize(width: 620, height: 380)
        panel.delegate = self

        let hosting = NSHostingView(rootView: RootView(store: store))
        hosting.frame = panel.contentLayoutRect
        panel.contentView = hosting

        restoreFrame(panel)
        return panel
    }
}

// MARK: - Root view

struct RootView: View {
    @ObservedObject var store: JournalStore

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 280)
        } detail: {
            EntryView(store: store)
        }
        .frame(minWidth: 620, minHeight: 380)
    }
}
