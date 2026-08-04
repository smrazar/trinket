import Foundation

/// One row in the centre list. The row *is* its own progress bar while running, so the state
/// machine here drives both the text and the accent fill sweeping behind it.
@MainActor
final class Item: Identifiable, ObservableObject {
    enum State: Equatable {
        case queued
        case running(fraction: Double)
        case done
        /// Amber. Nothing was wrong — there is simply nothing trinket can do to this yet.
        case passedThrough(reason: String)
        /// Amber. The user's settings ruled it out, or it was already smaller than the target.
        case skipped(reason: String)
        /// Red.
        case failed(reason: String)

        var isTerminal: Bool {
            switch self {
            case .queued, .running: return false
            default: return true
            }
        }

        var isFailure: Bool { if case .failed = self { return true }; return false }
    }

    let id = UUID()
    let url: URL
    let kind: Kind
    let badge: String
    let originalSize: Int64

    /// Set when this item came out of an archive, so the list can group it under the container
    /// and the runner knows not to write it back to the user's Downloads folder loose.
    let container: URL?

    @Published var state: State = .queued
    @Published var outputURL: URL?
    @Published var outputSize: Int64 = 0
    /// What the analyser predicts, before the run. Drives the estimate and the pre-run size pair.
    @Published var estimatedSize: Int64 = 0
    /// What this file was carrying, found during analysis.
    @Published var findings: [MetadataFinding] = []

    init(url: URL, container: URL? = nil) {
        self.url = url
        self.container = container
        self.kind = Identify.kind(of: url)
        self.badge = Identify.badge(for: url)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        self.originalSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        self.estimatedSize = originalSize
    }

    var name: String { url.lastPathComponent }

    /// The size to show on the right of the row: the real one once it exists, the estimate before.
    var shownSize: Int64 {
        switch state {
        case .done: return outputSize
        case .passedThrough, .skipped, .failed: return originalSize
        default: return estimatedSize
        }
    }

    /// `138.6 MB → 73.5 MB`, or just the one size when nothing changed. Mono, so it aligns.
    var sizePair: String? {
        switch state {
        case .passedThrough, .skipped, .failed: return nil
        default:
            guard shownSize != originalSize, shownSize > 0 else { return nil }
            return Bytes.pair(from: originalSize, to: shownSize)
        }
    }

    /// The accent-tinted pill. Nil when there is no saving to claim — a file that grew, or one
    /// that was left alone, must never show a percentage.
    var savings: Int? {
        switch state {
        case .passedThrough, .skipped, .failed: return nil
        default: return Bytes.savings(from: originalSize, to: shownSize)
        }
    }
}

/// The batch the user dropped. Owns the items, the analysis, the plan and the run.
@MainActor
final class Batch: ObservableObject {
    @Published var items: [Item] = []
    /// The container the user actually dropped, when they dropped one archive. Drives the list
    /// header: `Photos-1-001.zip · 41 items`.
    @Published var droppedContainer: URL?
    @Published var scrubReport = ScrubReport()

    var isEmpty: Bool { items.isEmpty }

    var totalOriginal: Int64 { items.reduce(0) { $0 + $1.originalSize } }
    var totalShown: Int64 { items.reduce(0) { $0 + $1.shownSize } }

    /// The same two totals, but **only over the files that were actually converted**.
    ///
    /// The headline must measure the work, not the drop. A 447 MB archive that passed through
    /// unchanged sat in both totals and dragged 894.9 MB → 890.9 MB, so the banner read
    /// "Saved 4.0 MB · 0% smaller" while every visible row said 98%. Technically true, and
    /// useless — the honest figure is what happened to the files something happened to. What was
    /// left alone is named separately, underneath.
    var convertedItems: [Item] {
        items.filter { if case .done = $0.state { return true }; return false }
    }

    var convertedOriginal: Int64 { convertedItems.reduce(0) { $0 + $1.originalSize } }
    var convertedShown: Int64 { convertedItems.reduce(0) { $0 + $1.shownSize } }

    /// Header title: the container's name if there was one, otherwise a count.
    var title: String {
        if let container = droppedContainer { return container.lastPathComponent }
        return items.count == 1 ? items[0].name : "\(items.count) files"
    }

    var subtitle: String {
        var counts: [Kind: Int] = [:]
        for item in items { counts[item.kind, default: 0] += 1 }
        let ordered = Kind.allCases.compactMap { kind in
            counts[kind].map { kind.counted($0) }
        }
        if droppedContainer != nil {
            return "\(items.count) items · " + ordered.joined(separator: ", ")
        }
        return ordered.joined(separator: ", ")
    }

    func counts(of kind: Kind) -> Int { items.filter { $0.kind == kind }.count }

    var kindsPresent: [Kind] {
        Kind.allCases.filter { counts(of: $0) > 0 }
    }

    func clear() {
        items = []
        droppedContainer = nil
        scrubReport = ScrubReport()
    }
}
