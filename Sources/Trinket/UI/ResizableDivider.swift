import SwiftUI
import AppKit

/// The draggable edge between a sidebar and the centre pane.
///
/// A plain `Divider()` is one hairline and nothing else. This is the same hairline with a wider
/// invisible grab area either side of it — a 1pt drag target is not hittable with a trackpad, so
/// the visible line stays 1pt and the *hit* area is `grabWidth`. Double-clicking snaps the pane
/// back to its shipped width, which is the AppKit convention and the only way back once someone
/// has dragged a pane to something unusable.
struct ResizableDivider: View {
    /// Which side of the divider the pane sits on. Dragging right must widen a left pane and
    /// narrow a right one.
    enum Side { case leading, trailing }

    @Binding var width: CGFloat
    let side: Side
    let range: ClosedRange<CGFloat>
    let defaultWidth: CGFloat

    /// Wide enough to grab, narrow enough not to steal clicks from the controls beside it.
    private let grabWidth: CGFloat = 10

    @State private var isHovering = false
    @State private var widthAtDragStart: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Tokens.Ink.line.color)
            .frame(width: 1)
            .frame(width: grabWidth)
            .contentShape(Rectangle())
            .background(isHovering ? Tokens.Ink.accentSoft.color : .clear)
            .onHover { hovering in
                isHovering = hovering
                // The cursor is the only thing that tells the user this edge is draggable.
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { drag in
                        // Anchor to the width at gesture start. Accumulating `translation` onto a
                        // width that is itself being updated squares the movement, so the pane
                        // shoots off under the pointer.
                        let start = widthAtDragStart ?? width
                        if widthAtDragStart == nil { widthAtDragStart = start }
                        let delta = side == .leading ? drag.translation.width : -drag.translation.width
                        width = (start + delta).clampedTo(range)
                    }
                    .onEnded { _ in widthAtDragStart = nil }
            )
            // Double-click resets. `simultaneousGesture` so it is not swallowed by the drag.
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    withAnimation(Tokens.Motion.stage) { width = defaultWidth }
                }
            )
            .accessibilityLabel("Resize panel")
            .help("Drag to resize · double-click to reset")
    }
}

extension CGFloat {
    func clampedTo(_ range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
