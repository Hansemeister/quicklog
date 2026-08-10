import AppKit
import SwiftUI

/// Drag handle between the entry list and the composer.
///
/// The gesture must measure in `.global` space: in local space the handle moves as
/// the height changes, so each frame reads a shifted origin and the divider
/// oscillates under the cursor.
struct ComposerDivider: View {
    @Binding var height: Double
    /// Applied on every drag frame, so the caller keeps ownership of the limits.
    let clamp: (Double) -> Double

    static let thickness: Double = 11

    @State private var dragStartHeight: Double?

    var body: some View {
        ZStack {
            Divider()
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 44, height: 4)
        }
        .frame(height: Self.thickness)
        .contentShape(Rectangle())
        .onHover { inside in
            Pointer.show(inside ? .resizeUpDown : nil)
        }
        .onDisappear { Pointer.show(nil) }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let base = dragStartHeight ?? height
                    if dragStartHeight == nil { dragStartHeight = base }
                    let dy = value.location.y - value.startLocation.y
                    height = clamp(base - dy)
                }
                .onEnded { _ in dragStartHeight = nil }
        )
        .help("Drag to resize")
    }
}
