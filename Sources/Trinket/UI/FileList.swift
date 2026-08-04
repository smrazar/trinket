import SwiftUI
import QuickLookThumbnailing

/// The centre column. The filename comes first and has the highest layout priority — it
/// middle-truncates only when genuinely out of room, and never before the numbers do.
struct FileList: View {
    @ObservedObject var batch: Batch
    let phase: Runner.Phase
    let plan: Blueprint
    let estimate: Estimate
    let failureNote: String?
    @Binding var selection: Set<UUID>
    let mode: ViewMode

    let onQuickLook: (Item) -> Void
    let onCompare: (Item) -> Void
    let onReveal: (Item) -> Void
    let onInspect: (Item) -> Void
    let onRemove: (Item) -> Void

    var body: some View {
        VStack(spacing: 0) {
            switch phase {
            case .finished:
                FinishedBanner(batch: batch, plan: plan, note: failureNote)
            case .running, .paused:
                runningHeader
            default:
                header
            }
            Hairline()
            rows
        }
        .background(Tokens.Ink.window.color)
    }

    // MARK: - Headers

    private var header: some View {
        HStack(spacing: Tokens.Space.sm) {
            Image(systemName: batch.droppedContainer != nil ? Symbols.containerHeader : Symbols.files)
                .font(.system(size: 12))
                .foregroundStyle(Tokens.Ink.inkTertiary.color)
            Text(batch.title)
                .font(Tokens.Face.heading)
                .foregroundStyle(Tokens.Ink.ink.color)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(batch.subtitle)
                .font(Tokens.Face.body)
                .foregroundStyle(Tokens.Ink.inkTertiary.color)
                .lineLimit(1)
            Spacer(minLength: Tokens.Space.md)
            if !selection.isEmpty {
                Text("\(selection.count) selected")
                    .font(Tokens.Face.body)
                    .foregroundStyle(Tokens.Ink.inkSecondary.color)
                    .fixedSize()
            }
        }
        .padding(.horizontal, Tokens.Space.xl)
        .padding(.vertical, Tokens.Space.lg)
    }

    private var runningHeader: some View {
        HStack(spacing: Tokens.Space.sm) {
            Image(systemName: Symbols.working)
                .font(.system(size: 12))
                .foregroundStyle(Tokens.Ink.accent.color)
                .symbolEffect(.rotate, options: .repeating)
            Text(phase == .paused ? "Paused" : "Working through the pile…")
                .font(Tokens.Face.heading)
                .foregroundStyle(Tokens.Ink.ink.color)
            Spacer()
            Text(remaining)
                .font(Tokens.Face.mono)
                .foregroundStyle(Tokens.Ink.inkTertiary.color)
        }
        .padding(.horizontal, Tokens.Space.xl)
        .padding(.vertical, Tokens.Space.lg)
    }

    private var remaining: String {
        let done = batch.items.filter { $0.state.isTerminal }.count
        return "\(done) of \(batch.items.count)"
    }

    // MARK: - Rows

    @ViewBuilder
    private var rows: some View {
        ScrollView {
            if mode == .thumbnails {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: FileTile.tile), spacing: Tokens.Space.md)],
                          spacing: Tokens.Space.lg) {
                    ForEach(batch.items) { item in
                        FileTile(item: item, isSelected: selection.contains(item.id))
                            .onTapGesture { toggle(item) }
                            .contextMenu { menu(for: item) }
                    }
                }
                .padding(Tokens.Space.lg)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(batch.items) { item in
                        FileRow(item: item,
                                isSelected: selection.contains(item.id),
                                isDetailed: mode == .detail)
                            .contentShape(Rectangle())
                            .onTapGesture { toggle(item) }
                            .contextMenu { menu(for: item) }
                        Hairline()
                    }
                }
            }
        }
    }

    /// The three per-row buttons left the row for the toolbar, and stay reachable here.
    @ViewBuilder
    private func menu(for item: Item) -> some View {
        Button("Quick Look") { onQuickLook(item) }
        Button("Compare before / after") { onCompare(item) }
            .disabled(item.outputURL == nil)
        Button("Show in Finder") { onReveal(item) }
        Divider()
        Button("Inspect metadata…") { onInspect(item) }
        Button("Copy path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.url.path, forType: .string)
        }
        Divider()
        Button("Remove from queue") { onRemove(item) }
            .disabled(phase == .running || phase == .paused)
    }

    private func toggle(_ item: Item) {
        if NSEvent.modifierFlags.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        } else {
            selection = [item.id]
        }
    }
}

// MARK: - Row

/// `[kind badge] filename … [size pair] [savings pill]`. While running, the row **is** its own
/// progress bar — the accent fill sweeps behind the text rather than a separate bar appearing.
struct FileRow: View {
    @ObservedObject var item: Item
    let isSelected: Bool
    /// The two-line form: a thumbnail, and a second line carrying the path and the detail the
    /// compact row has no room for.
    var isDetailed = false

    var body: some View {
        HStack(spacing: Tokens.Space.md) {
            if isDetailed {
                FileThumbnail(url: item.outputURL ?? item.url, fallback: item.url,
                              kind: item.kind, size: 38)
            }
            KindBadge(text: item.badge)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(Tokens.Face.body)
                    .foregroundStyle(nameColour)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isDetailed {
                    Text(secondLine)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Tokens.Ink.inkTertiary.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .layoutPriority(1)              // the filename yields last, after the numbers

            Spacer(minLength: Tokens.Space.sm)

            trailing
        }
        .padding(.horizontal, Tokens.Space.rowH)
        .padding(.vertical, isDetailed ? Tokens.Space.sm + 2 : Tokens.Space.rowV)
        .background(background)
        .animation(Tokens.Motion.quick, value: isSelected)
    }

    /// What the compact row cannot fit: where the file came from, and what it carries.
    private var secondLine: String {
        var parts: [String] = []
        let folder = item.url.deletingLastPathComponent().lastPathComponent
        if !folder.isEmpty { parts.append(folder) }
        if item.container != nil { parts.append("in \(item.container!.lastPathComponent)") }
        if !item.findings.isEmpty {
            parts.append("\(item.findings.count) metadata \(item.findings.count == 1 ? "item" : "items")")
        }
        if case .failed(let reason) = item.state { parts.append(reason) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var trailing: some View {
        switch item.state {
        case .queued:
            StatusTag(text: "Queued", tone: .quiet)
            sizeText(Bytes.format(item.originalSize))

        case .running(let fraction):
            Text("\(Int((fraction * 100).rounded()))%")
                .font(Tokens.Face.monoStrong)
                .foregroundStyle(Tokens.Ink.accent.color)
                .fixedSize()

        case .done:
            if let pair = item.sizePair {
                Text(pair)
                    .font(Tokens.Face.mono)
                    .foregroundStyle(Tokens.Ink.inkSecondary.color)
                    .fixedSize()
            } else {
                sizeText(Bytes.format(item.shownSize))
            }
            if let saving = item.savings {
                SavingsPill(percent: saving)
            }

        case .passedThrough(let reason):
            StatusTag(text: shortReason(reason), tone: .amber, icon: Symbols.notYet)
            sizeText(Bytes.format(item.originalSize))

        case .skipped(let reason):
            StatusTag(text: shortReason(reason), tone: .amber)
            sizeText(Bytes.format(item.originalSize))

        case .failed(let reason):
            StatusTag(text: shortReason(reason), tone: .red, icon: Symbols.failed)
            sizeText(Bytes.format(item.originalSize))
        }
    }

    private func sizeText(_ text: String) -> some View {
        Text(text)
            .font(Tokens.Face.mono)
            .foregroundStyle(Tokens.Ink.inkTertiary.color)
            .fixedSize()
    }

    /// A row tag has room for a phrase, not a sentence. The whole reason stays in the log and in
    /// the tooltip.
    private func shortReason(_ reason: String) -> String {
        if reason.contains("no video encoder") { return "No encoder" }
        if reason.contains("stays packed") { return "Stays packed" }
        if reason.contains("passes through") { return "Unchanged" }
        let firstSentence = reason.split(separator: ".").first.map(String.init) ?? reason
        return firstSentence.count > 34 ? String(firstSentence.prefix(32)) + "…" : firstSentence
    }

    private var nameColour: Color {
        switch item.state {
        case .queued, .passedThrough, .skipped: return Tokens.Ink.inkSecondary.color
        case .failed: return Tokens.Ink.ink.color
        default: return Tokens.Ink.ink.color
        }
    }

    /// The running row draws its own progress: an accent tint sweeping across from the left.
    @ViewBuilder
    private var background: some View {
        if case .running(let fraction) = item.state {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Tokens.Ink.accentTint + 0.45
                    Tokens.Ink.accentTint.color
                        .frame(width: geometry.size.width * fraction)
                        .animation(Tokens.Motion.stage, value: fraction)
                }
            }
        } else if isSelected {
            Tokens.Ink.accentTint.color
        } else {
            Color.clear
        }
    }
}

// MARK: - Finished banner

/// The payoff. The total saved reads in accent; anything that could not be done is said plainly
/// underneath rather than left out.
struct FinishedBanner: View {
    @ObservedObject var batch: Batch
    let plan: Blueprint
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.sm) {
            Label("Done", systemImage: Symbols.done)
                .font(Tokens.Face.label)
                .tracking(Tokens.Face.labelTracking)
                .foregroundStyle(Tokens.Ink.green.color)

            if saved > 0 {
                // One wrapping Text rather than an HStack of three. An HStack cannot break
                // between its children, so at a narrow window the 28pt headline ran off the edge
                // instead of moving onto a second line. `Text + Text` keeps the per-run colour
                // and still wraps like ordinary prose.
                (Text("Saved ").foregroundColor(Tokens.Ink.ink.color)
                    + Text(Bytes.format(saved)).foregroundColor(Tokens.Ink.accent.color)
                    + Text(" across \(changedCount) \(changedCount == 1 ? "file" : "files")")
                        .foregroundColor(Tokens.Ink.ink.color))
                    .font(Tokens.Face.display)
                    .fixedSize(horizontal: false, vertical: true)

                (Text(Bytes.pair(from: batch.convertedOriginal, to: batch.convertedShown))
                    .font(Tokens.Face.mono).foregroundColor(Tokens.Ink.inkSecondary.color)
                    + Text(" — ").foregroundColor(Tokens.Ink.inkTertiary.color)
                    + Text("\(percent)% smaller")
                        .font(Tokens.Face.bodyStrong).foregroundColor(Tokens.Ink.ink.color)
                    + Text(", and safe to send.")
                        .font(Tokens.Face.body).foregroundColor(Tokens.Ink.inkSecondary.color))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Honest: nothing got smaller. Saying so is better than a 0% headline.
                Text("Nothing left to squeeze")
                    .font(Tokens.Face.display)
                    .foregroundStyle(Tokens.Ink.ink.color)
                Text("These files were already as small as they get.")
                    .font(Tokens.Face.body)
                    .foregroundStyle(Tokens.Ink.inkSecondary.color)
            }

            ForEach(untouchedNotes, id: \.self) { text in
                Label(text, systemImage: Symbols.notYet)
                    .font(Tokens.Face.body)
                    .foregroundStyle(Tokens.Ink.amber.color)
            }

            if failedCount > 0 {
                Label("\(failedCount) \(failedCount == 1 ? "file" : "files") could not be converted.",
                      systemImage: Symbols.failed)
                    .font(Tokens.Face.body)
                    .foregroundStyle(Tokens.Ink.red.color)
            }

            if let note {
                Text(note)
                    .font(Tokens.Face.body)
                    .foregroundStyle(Tokens.Ink.red.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Tokens.Space.xl)
        .padding(.vertical, Tokens.Space.xl)
        .background(Tokens.Ink.accentTint + 0.35)
    }

    // Over the converted files only — see `Batch.convertedItems` for why.
    private var saved: Int64 {
        max(0, batch.convertedOriginal - batch.convertedShown)
    }

    private var percent: Int {
        Bytes.savings(from: batch.convertedOriginal, to: batch.convertedShown) ?? 0
    }

    private var changedCount: Int { batch.convertedItems.count }

    private var failedCount: Int {
        batch.items.filter(\.state.isFailure).count
    }

    private var untouchedNotes: [String] {
        var notes: [String] = []
        let passed = batch.items.filter {
            if case .passedThrough = $0.state { return true }
            return false
        }
        if !passed.isEmpty {
            var byKind: [Kind: Int] = [:]
            for item in passed { byKind[item.kind, default: 0] += 1 }
            for (kind, count) in byKind.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                // Do not name a reason here. The row already carries the specific one, and the
                // banner guessing "video shrink is coming" outlived the limitation it described.
                notes.append("\(kind.counted(count)) passed through unchanged.")
            }
        }
        return notes
    }
}
