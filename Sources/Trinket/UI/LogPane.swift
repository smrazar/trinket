import SwiftUI

/// The log is a **right sidebar**, symmetrical with the plan on the left — not a separate window.
/// Flat `#fbfbfd`, dense SF Mono: no frost. Legibility wins over the material effect here; a
/// blurred backdrop behind 12px monospace is exactly where frost stops being decoration and
/// starts costing readability.
struct LogPane: View {
    @ObservedObject var logbook: Logbook
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            lines
            Hairline()
            footer
        }
        .frame(maxWidth: .infinity)
        .background(Tokens.Ink.logBg.color)
    }

    private var header: some View {
        HStack {
            GroupHeading(text: "Log")
            Spacer()
            ToolbarButton(icon: Symbols.copy, help: "Copy the log") { logbook.copyAll() }
            ToolbarButton(icon: Symbols.clear, help: "Clear the log") { logbook.clear() }
            ToolbarButton(icon: Symbols.close, help: "Hide the log", action: onClose)
        }
        .padding(.horizontal, Tokens.Space.lg)
        .padding(.vertical, Tokens.Space.md)
    }

    private var lines: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(logbook.lines) { line in
                        HStack(alignment: .top, spacing: Tokens.Space.sm) {
                            Text(line.stamp)
                                .font(Tokens.Face.mono)
                                .foregroundStyle(colour(line.level).opacity(0.75))
                                .fixedSize()
                            Text(line.text)
                                .font(Tokens.Face.mono)
                                .foregroundStyle(colour(line.level))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(line.id)
                        .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, Tokens.Space.lg)
                .padding(.vertical, Tokens.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: logbook.lines.count) { _, _ in
                guard let last = logbook.lines.last else { return }
                withAnimation(Tokens.Motion.quick) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var footer: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([logbook.fileURL])
        } label: {
            Text(logbook.displayPath)
                .font(Tokens.Face.mono)
                .foregroundStyle(Tokens.Ink.inkTertiary.color)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Tokens.Space.lg)
                .padding(.vertical, Tokens.Space.md)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show the log file in Finder")
    }

    private func colour(_ level: LogLine.Level) -> Color {
        switch level {
        case .info: return Tokens.Ink.logInk.color
        case .warn: return Tokens.Ink.amber.color
        case .fail: return Tokens.Ink.red.color
        }
    }
}
