import SwiftUI
import AppKit

/// The compact result card that appears after a batch finishes.
///
/// The point is that the main window is usually **behind** something by the time a long batch
/// ends — you started it and went back to work. A payoff line nobody sees is not a payoff. This
/// floats above everything for a few seconds, says what happened, and offers the one action worth
/// offering: show me.
///
/// It is deliberately not a notification. A notification is a different app's UI, it queues behind
/// whatever else is pending, and it cannot be clicked through to a Finder selection reliably.
@MainActor
final class FloatingResultController {
    static let shared = FloatingResultController()

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    /// How long it lingers before fading. Long enough to read a sentence, short enough not to be
    /// in the way.
    private static let lifetime: Duration = .seconds(6)

    struct Result {
        let saved: Int64
        let percent: Int
        let fileCount: Int
        let failedCount: Int
        let untouchedCount: Int
        /// Where "Show me" goes.
        let reveal: URL?
    }

    func show(_ result: Result, onReveal: @escaping () -> Void) {
        dismiss()

        let view = FloatingResultCard(result: result,
                                      onReveal: { [weak self] in onReveal(); self?.dismiss() },
                                      onClose: { [weak self] in self?.dismiss() })

        // `.nonactivatingPanel` so showing the card does not steal focus from whatever the user
        // moved on to — the whole reason the card exists is that they are doing something else.
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 150),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        // Follows the user across Spaces rather than being stranded on the one they launched from.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hosting = NSHostingView(rootView: view)
        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        position(panel)
        panel.orderFrontRegardless()
        self.panel = panel

        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: Self.lifetime)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// Top-right of the screen holding the pointer, under the menu bar and inset from the edge.
    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 20,
                                     y: visible.maxY - size.height - 20))
    }
}

/// The card itself.
struct FloatingResultCard: View {
    let result: FloatingResultController.Result
    let onReveal: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.sm) {
            HStack(spacing: Tokens.Space.sm) {
                TrinketMark(size: 18)
                Text("trinket")
                    .font(Tokens.Face.label)
                    .tracking(Tokens.Face.labelTracking)
                    .foregroundStyle(Tokens.Ink.inkTertiary.color)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: Symbols.close)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Tokens.Ink.inkTertiary.color)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // The headline, in the same words the finished banner uses — one payoff, phrased once.
            if result.saved > 0 {
                (Text("Saved ").foregroundColor(Tokens.Ink.ink.color)
                    + Text(Bytes.format(result.saved)).foregroundColor(Tokens.Ink.accent.color))
                    .font(Tokens.Face.heading)
                Text("\(result.percent)% smaller across \(result.fileCount) "
                     + "\(result.fileCount == 1 ? "file" : "files").")
                    .font(Tokens.Face.body)
                    .foregroundStyle(Tokens.Ink.inkSecondary.color)
            } else {
                Text("Nothing left to squeeze")
                    .font(Tokens.Face.heading)
                    .foregroundStyle(Tokens.Ink.ink.color)
                Text("These files were already as small as they get.")
                    .font(Tokens.Face.body)
                    .foregroundStyle(Tokens.Ink.inkSecondary.color)
            }

            // The honest tail, same rule as everywhere else: say what did not happen.
            if result.failedCount > 0 {
                Label("\(result.failedCount) failed", systemImage: Symbols.failed)
                    .font(Tokens.Face.body)
                    .foregroundStyle(Tokens.Ink.red.color)
            } else if result.untouchedCount > 0 {
                Label("\(result.untouchedCount) passed through unchanged", systemImage: Symbols.notYet)
                    .font(Tokens.Face.body)
                    .foregroundStyle(Tokens.Ink.amber.color)
            }

            Spacer(minLength: 0)

            PrimaryButton(title: "Show in Finder", icon: Symbols.reveal, action: onReveal)
        }
        .padding(Tokens.Space.lg)
        .frame(width: 340, height: 150, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .fill(Tokens.Ink.window.color)
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                        .strokeBorder(Tokens.Ink.line.color, lineWidth: 1)
                )
        )
    }
}
