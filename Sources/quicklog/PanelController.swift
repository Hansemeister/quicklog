import AppKit
import SwiftUI

/// Floating panel that stays above other apps' windows and can take key focus.
final class QuicklogPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// What esc does. Set by `PanelController` so an in-progress entry edit is
    /// cancelled first and only a second esc hides the panel.
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        if let onCancel {
            onCancel()
        } else {
            orderOut(nil)
        }
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
        panel?.orderOut(nil)
    }

    // MARK: Frame persistence
    //
    // windowDidMove/windowDidResize fire live, so the stored frame is always
    // current — no need to save on hide or close.

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }

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
        // Ignore a frame left on a screen that is no longer attached.
        guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) else {
            panel.center()
            return
        }
        panel.setFrame(rect, display: false)
    }

    // MARK: Setup

    private func makePanel() -> QuicklogPanel {
        let panel = QuicklogPanel(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            // No .fullSizeContentView: the header bar must sit below the
            // titlebar, not under the traffic lights.
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
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
        panel.onCancel = { [weak self] in
            guard let self else { return }
            if store.editingEntryID != nil {
                store.cancelEdit()
            } else {
                hide()
            }
        }

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
    @State private var hoverHint: String?

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            NavigationSplitView {
                SidebarView(store: store)
                    .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 280)
            } detail: {
                EntryView(store: store)
            }
        }
        .frame(minWidth: 620, minHeight: 380)
    }

    /// Undo/redo for entry changes (save, edit, delete). Buttons rather than a
    /// key binding — ⌘Z belongs to the text field, and a second chord for the
    /// journal was invisible.
    private var headerBar: some View {
        HStack(spacing: 4) {
            headerButton(
                systemName: "arrow.uturn.backward",
                hint: "Undo last change",
                enabled: store.canUndo,
                action: store.undo
            )
            headerButton(
                systemName: "arrow.uturn.forward",
                hint: "Redo last change",
                enabled: store.canRedo,
                action: store.redo
            )

            // Fixed slot, so revealing the label never reflows the bar.
            Text(hoverHint ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .opacity(hoverHint == nil ? 0 : 1)
                .animation(.easeInOut(duration: 0.12), value: hoverHint)
                .padding(.leading, 4)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func headerButton(
        systemName: String,
        hint: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 20, height: 18)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(hint)
        .onHover { inside in
            if inside {
                hoverHint = enabled ? hint : "\(hint) — nothing to do"
            } else if hoverHint?.hasPrefix(hint) == true {
                hoverHint = nil
            }
        }
    }
}
