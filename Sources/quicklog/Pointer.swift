import AppKit

/// The app's only pointer-shape override.
///
/// `NSCursor.push()`/`pop()` and `NSCursor.set()` do not mix: `set` doesn't touch
/// the stack, so a cursor left pushed by one view resurfaces on the next cursor
/// update after another view "set" its own. And a push that is never popped —
/// a row deleted under the pointer, a view torn down mid-hover — is the wrong
/// cursor everywhere until the app restarts.
///
/// So: one outstanding push, ever, through here. Views say what they want the
/// pointer to look like and `nil` when they stop caring; teardown says `nil` too.
@MainActor
enum Pointer {
    private static var pushed: NSCursor?

    static func show(_ cursor: NSCursor?) {
        guard cursor !== pushed else { return }
        if pushed != nil { NSCursor.pop() }
        pushed = cursor
        cursor?.push()
    }
}
