import AppKit
import Carbon.HIToolbox
import SwiftUI

/// ↑/↓ at the edge of a text view step between the composer and the entries above
/// it, so a run of notes can be reviewed without the mouse.
///
/// A local `NSEvent` monitor rather than a custom `NSTextView`: `TextEditor`
/// exposes no key handling, and replacing it would mean owning the text system.
private struct ArrowNavigation: ViewModifier {
    let store: JournalStore
    /// Which end of the next editor the caret belongs at — top when arriving from
    /// above. Owned by the view that shows the editor.
    @Binding var arrivingFromAbove: Bool
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    handle(event) ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }

    /// True when the event was handled and should not travel further.
    private func handle(_ event: NSEvent) -> Bool {
        let up = UInt16(kVK_UpArrow)
        let down = UInt16(kVK_DownArrow)
        // Arrow keys always carry `.function` and `.numericPad`, so only the
        // modifiers a person can hold down disqualify the event.
        let held: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        guard event.keyCode == up || event.keyCode == down,
              event.modifierFlags.intersection(held).isEmpty,
              let window = event.window as? QuicklogPanel,
              let editor = window.firstResponder as? NSTextView
        else { return false }

        // Let the text view move the caret first: it knows where wrapped lines
        // break, and a caret that then hasn't moved is what "already at the
        // edge" means. Either way the move is done, so the event is spent.
        let before = editor.selectedRange().location
        if event.keyCode == up { editor.moveUp(nil) } else { editor.moveDown(nil) }
        guard editor.selectedRange().location == before else { return true }

        arrivingFromAbove = event.keyCode != up
        return event.keyCode == up ? store.editEntryAbove() : store.editEntryBelow()
    }
}

extension View {
    func arrowNavigation(store: JournalStore, arrivingFromAbove: Binding<Bool>) -> some View {
        modifier(ArrowNavigation(store: store, arrivingFromAbove: arrivingFromAbove))
    }
}
