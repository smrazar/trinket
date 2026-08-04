import Foundation

/// Executes a Blueprint. This is the piece that makes the plan real: the queue runs the *stages
/// the analyser chose*, in order, per lane — not one flat settings object applied to everything.
///
/// Lanes are independent, so photos re-encode while a video transcodes. Everything converges on
/// the Bundle stage, which by definition cannot start until every lane has finished.
@MainActor
final class Runner: ObservableObject {

    enum Phase: Equatable {
        case idle
        case analysing
        case ready
        case running
        case paused
        case finished
        case cancelled
    }

    @Published private(set) var phase: Phase = .idle
    /// 0…1 across the whole batch.
    @Published private(set) var progress: Double = 0
    @Published private(set) var completedCount = 0
    @Published private(set) var bundleURL: URL?
    /// Set when the run ends for a reason worth showing at the top of the list.
    @Published private(set) var failureNote: String?

    private var task: Task<Void, Never>?
    private var isPaused = false
    /// How to name results this run. Captured at the start so a mid-run settings change cannot
    /// name half the batch one way and half the other.
    private var renaming = Renaming()
    /// Stamped once per run, so every file in a batch shares one {date}/{time}.
    private var runStamp = (date: "", time: "")
    /// Temporary folders this run created, removed when it ends however it ends.
    private var scratch: [URL] = []

    var isRunning: Bool { phase == .running || phase == .paused }

    // MARK: - Running

    func run(batch: Batch, plan: Blueprint, defaults: Defaults) {
        guard !isRunning else { return }
        phase = .running
        progress = 0
        completedCount = 0
        bundleURL = nil
        failureNote = nil
        isPaused = false

        let items = batch.items
        let destination = defaults.outputFolder
        let originalHandling = defaults.originalHandling
        let location = defaults.outputLocation
        renaming = defaults.renaming

        task = Task { [weak self] in
            await self?.execute(items: items,
                                plan: plan,
                                destination: destination,
                                location: location,
                                originalHandling: originalHandling,
                                batch: batch)
        }
    }

    private func execute(items: [Item],
                         plan: Blueprint,
                         destination: URL,
                         location: OutputLocation,
                         originalHandling: OriginalHandling,
                         batch: Batch) async {
        logInfo("run: \(plan.stepLabel) · \(items.count) files")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let now = Date()
        runStamp.date = formatter.string(from: now)
        formatter.dateFormat = "HH-mm-ss"
        runStamp.time = formatter.string(from: now)
        if renaming.isEnabled { logInfo("rename: \(renaming.pattern)") }

        totalBytes = max(1, items.reduce(Int64(0)) { $0 + max($1.originalSize, 1) })
        finishedBytes = 0
        inFlightBytes = 0

        // Where each result goes. An archive's contents are assembled in their own scratch folder
        // so they can be repacked into one archive at the end — and so a failure half way through
        // never leaves a pile of loose entries in the user's Downloads. Files the user dropped
        // loose are written straight out: an archive in, an archive out; loose files in, loose
        // files out. Zipping something the user did not hand us zipped would be a surprise.
        var staging: [URL: URL] = [:]
        if plan.bundle.enabled {
            for container in Set(items.compactMap(\.container)) {
                let folder = FileManager.default.temporaryDirectory
                    .appending(path: "trinket-stage-\(UUID().uuidString)", directoryHint: .isDirectory)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                staging[container] = folder
                scratch.append(folder)
            }
        }
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        // Resolve every destination up front, on the main actor where the items live, so the lane
        // tasks are handed plain URLs rather than a closure that reads main-actor state.
        var destinations: [UUID: URL] = [:]
        for item in items {
            if let container = item.container, let folder = staging[container] {
                destinations[item.id] = folder
            } else if let container = item.container {
                // Its archive is not being repacked, so the entry stands on its own.
                destinations[item.id] = Self.looseDestination(for: container, location: location,
                                                              fallback: destination)
            } else {
                destinations[item.id] = Self.looseDestination(for: item.url, location: location,
                                                              fallback: destination)
            }
        }

        // One task group per lane, so lanes genuinely run in parallel and converge below.
        await withTaskGroup(of: Void.self) { group in
            for lane in plan.lanes {
                let laneItems = items.filter { $0.kind == lane.kind }
                guard !laneItems.isEmpty else { continue }
                group.addTask { [weak self] in
                    await self?.runLane(lane, items: laneItems, plan: plan, destinations: destinations)
                }
            }
        }

        guard !Task.isCancelled, phase != .cancelled else {
            cleanUp()
            phase = .cancelled
            return
        }

        // Everything converges here — one archive out per archive in.
        for (container, folder) in staging {
            bundle(plan: plan, container: container, from: folder,
                   into: Self.looseDestination(for: container, location: location, fallback: destination))
        }

        if originalHandling != .keep {
            disposeOriginals(items, handling: originalHandling)
        }

        cleanUp()
        progress = 1
        phase = .finished

        let saved = items.reduce(Int64(0)) { $0 + max(0, $1.originalSize - $1.shownSize) }
        logInfo("done — saved \(Bytes.format(saved))")
    }

    private func runLane(_ lane: Lane, items: [Item], plan: Blueprint,
                         destinations: [UUID: URL]) async {
        guard let stage = lane.shrink else {
            // No stage for this kind: say so on every row rather than leaving them queued
            // forever or showing a progress bar that never moves.
            //
            // The file must still be *carried through* — marking a row amber and not copying it
            // is how an entry disappears out of a repacked archive. Every pass-through in this
            // file routes through `copyThrough` for exactly that reason.
            let reason = plan.caveats.first(where: { $0.isNotYet })?.text ?? "passes through unchanged"
            for item in items {
                item.outputURL = try? copyThrough(item, into: destinations[item.id] ?? item.url.deletingLastPathComponent())
                item.outputSize = item.originalSize
                item.state = .passedThrough(reason: reason)
                advance(item)
            }
            return
        }

        for (index, item) in items.enumerated() {
            await waitWhilePaused()
            if Task.isCancelled || phase == .cancelled { return }

            item.state = .running(fraction: 0)
            do {
                switch try process(item, stage: stage, scrub: plan.scrub,
                                   into: destinations[item.id] ?? item.url.deletingLastPathComponent()) {
                case .converted(let url, let size):
                    // Renamed after writing, not before: only now is the real extension known,
                    // and {w}/{h} need the file that actually landed.
                    let finalURL = rename(url, for: item, index: index)
                    // Stamped so a later drop of the same folder does not re-encode this.
                    Marker.stamp(finalURL)
                    item.outputURL = finalURL
                    item.outputSize = size
                    item.state = .done
                    if let saving = item.savings {
                        logInfo("\(item.name) → \(Bytes.format(size)) (\(saving)% smaller)")
                    } else {
                        logInfo("\(item.name) → \(Bytes.format(size))")
                    }
                case .carried(let url, let reason):
                    // Copied through untouched. Amber, named, and never a progress bar that lies.
                    item.outputURL = url
                    item.outputSize = item.originalSize
                    item.state = .passedThrough(reason: reason)
                    logWarn("\(item.name) — \(reason)")
                }
            } catch let error as ImagePass.Failure {
                fail(item, error.localizedDescription)
            } catch let error as DocumentPass.Failure {
                // A document trinket cannot rewrite is not a failure of the run — it is a file
                // that passes through, and the row says which.
                if case .unsupported = error {
                    item.state = .passedThrough(reason: error.localizedDescription)
                    item.outputSize = item.originalSize
                    logWarn("\(item.name) — \(error.localizedDescription)")
                } else {
                    fail(item, error.localizedDescription)
                }
            } catch let error as MediaPass.Failure {
                fail(item, error.localizedDescription)
            } catch {
                fail(item, error.localizedDescription)
            }
            advance(item)
        }
    }

    /// What one file's turn produced. `carried` is not a failure — the file was copied through
    /// untouched, which is a real outcome with its own colour, not an error to be swallowed.
    private enum Produced {
        case converted(url: URL, size: Int64)
        case carried(url: URL, reason: String)
    }

    private func process(_ item: Item, stage: ShrinkStage, scrub: ScrubLevel, into destination: URL) throws -> Produced {
        // Being inside an archive changes nothing about what can be done to a file. The old
        // engine could only re-encode images in place, so archive shrink was images-only; here an
        // entry is unpacked to disk first and goes through exactly the same pass a loose file
        // does. Gating on the container was a rule carried over from an engine that no longer
        // exists, and it silently passed every video inside a zip through at full size.
        switch item.kind {
        case .image:
            let outcome = try ImagePass.run(item.url, stage: stage, scrub: scrub, into: destination)
            return .converted(url: outcome.outputURL, size: outcome.size)
        case .document:
            let outcome = try DocumentPass.run(item.url, stage: stage, scrub: scrub, into: destination)
            return .converted(url: outcome.outputURL, size: outcome.size)
        case .audio:
            let outcome = try MediaPass.runAudio(item.url, stage: stage, into: destination)
            return .converted(url: outcome.outputURL, size: outcome.size)
        case .video:
            // The one kind slow enough that a still bar reads as a crash. ffmpeg reports its
            // progress; the closure hops to the main actor because it fires on a pipe queue.
            let outcome = try MediaPass.runVideo(item.url, stage: stage, scrub: scrub,
                                                 into: destination) { [weak self] fraction in
                Task { @MainActor in self?.advanceWithin(item, fraction: fraction) }
            }
            return .converted(url: outcome.outputURL, size: outcome.size)
        case .archive:
            return .carried(url: try copyThrough(item, into: destination),
                            reason: "stays packed — trinket opens one layer, not two")
        case .other:
            return .carried(url: try copyThrough(item, into: destination),
                            reason: "passes through unchanged")
        }
    }

    /// Where a result goes when it is not being repacked into an archive. "Beside the original"
    /// writes into the source's own folder — but only somewhere actually writable; a file opened
    /// from a read-only volume or a DMG falls back to the output folder rather than failing.
    nonisolated static func looseDestination(for source: URL,
                                             location: OutputLocation,
                                             fallback: URL) -> URL {
        guard location == .besideOriginal else { return fallback }
        let beside = source.deletingLastPathComponent()
        return FileManager.default.isWritableFile(atPath: beside.path) ? beside : fallback
    }

    /// Applies the naming pattern to a written file. Failure is not fatal — a file that could
    /// not be renamed is still a converted file, and losing it to a naming error would be worse
    /// than an unexpected name.
    private func rename(_ url: URL, for item: Item, index: Int) -> URL {
        guard renaming.isEnabled else { return url }

        var context = Renaming.Context(
            originalName: item.url.deletingPathExtension().lastPathComponent,
            newExtension: url.pathExtension,
            kind: item.kind,
            index: index,
            parent: item.url.deletingLastPathComponent().lastPathComponent,
            date: runStamp.date,
            time: runStamp.time)
        if item.kind == .image {
            let size = ImagePass.pixelSize(of: url)
            context.width = size.width
            context.height = size.height
        }

        let base = renaming.apply(context)
        let ext = renaming.newExtension(from: url.pathExtension, context: context)
        let name = ext.isEmpty ? base : "\(base).\(ext)"
        guard name != url.lastPathComponent else { return url }
        guard let target = try? ArchivePass.unusedURL(named: name,
                                                      in: url.deletingLastPathComponent()),
              (try? FileManager.default.moveItem(at: url, to: target)) != nil else {
            logWarn("could not rename \(url.lastPathComponent)")
            return url
        }
        return target
    }

    private func copyThrough(_ item: Item, into destination: URL) throws -> URL {
        let copy = try ArchivePass.unusedURL(named: item.name, in: destination)
        try FileManager.default.copyItem(at: item.url, to: copy)
        Marker.stamp(copy)
        return copy
    }

    private func bundle(plan: Blueprint, container: URL, from staging: URL, into destination: URL) {
        let name = container.deletingPathExtension().lastPathComponent + "-trinket"
        do {
            let archive = try ArchivePass.bundle(staging, named: name,
                                                 level: plan.bundle.level, into: destination)
            bundleURL = archive
            Marker.stamp(archive)
            logInfo("bundle → \(archive.lastPathComponent)")
        } catch {
            // The files exist; only the packing failed. Move them out of the scratch folder so
            // the work is not thrown away, and say what happened.
            failureNote = "The files were converted, but the archive could not be written: \(error.localizedDescription)"
            logFail("bundle failed — \(error.localizedDescription)")
            rescue(from: staging, into: destination)
        }
    }

    /// The bundle failed; the converted files must not vanish with the scratch folder.
    private func rescue(from staging: URL, into destination: URL) {
        for file in ArchivePass.walk(staging) {
            guard let target = try? ArchivePass.unusedURL(named: file.lastPathComponent, in: destination)
            else { continue }
            try? FileManager.default.moveItem(at: file, to: target)
        }
    }

    private func disposeOriginals(_ items: [Item], handling: OriginalHandling) {
        for item in items {
            // Only touch an original that actually produced something, and never touch a file
            // that came out of an archive — it lives in a scratch folder, not the user's disk.
            guard item.container == nil, case .done = item.state, item.outputURL != nil else { continue }
            switch handling {
            case .keep:
                break
            case .trash, .replace:
                // Both go through the Trash. `replace` differs only in that the result is then
                // moved into the original's folder — deleting outright is not recoverable, and
                // this is the one action in the app that destroys the user's data.
                var trashed: NSURL?
                try? FileManager.default.trashItem(at: item.url, resultingItemURL: &trashed)
                if handling == .replace, let output = item.outputURL {
                    let beside = item.url.deletingLastPathComponent()
                        .appending(path: output.lastPathComponent)
                    if let target = try? ArchivePass.unusedURL(named: beside.lastPathComponent,
                                                              in: beside.deletingLastPathComponent()),
                       (try? FileManager.default.moveItem(at: output, to: target)) != nil {
                        item.outputURL = target
                    }
                }
            }
        }
    }

    // MARK: - Control

    func pause() {
        guard phase == .running else { return }
        isPaused = true
        phase = .paused
        logInfo("paused")
    }

    func resume() {
        guard phase == .paused else { return }
        isPaused = false
        phase = .running
        logInfo("resumed")
    }

    func cancel() {
        guard isRunning else { return }
        isPaused = false
        phase = .cancelled
        task?.cancel()
        logWarn("cancelled")
    }

    func reset() {
        task?.cancel()
        task = nil
        cleanUp()
        phase = .idle
        progress = 0
        completedCount = 0
        bundleURL = nil
        failureNote = nil
    }

    private func waitWhilePaused() async {
        while isPaused, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(120))
        }
    }

    private func fail(_ item: Item, _ reason: String) {
        item.state = .failed(reason: reason)
        logFail("\(item.name) — \(reason)")
    }

    /// Progress is weighted by **bytes**, not by file count. Twenty photos and one 200 MB video
    /// is 21 files, so a per-file count reaches 95% within a second and then sits there for four
    /// minutes — which is worse than no bar at all.
    private var totalBytes: Int64 = 1
    private var finishedBytes: Int64 = 0
    /// How far through the file currently being worked on, weighted by its size.
    private var inFlightBytes: Int64 = 0

    private func advance(_ item: Item) {
        completedCount += 1
        finishedBytes += max(item.originalSize, 1)
        inFlightBytes = 0
        recomputeProgress()
    }

    /// Called as a single file reports its own progress, so the batch bar moves *within* a file
    /// rather than only between files.
    private func advanceWithin(_ item: Item, fraction: Double) {
        // ffmpeg's last progress block can land *after* the process exits and the row is already
        // marked done — which flipped a finished row back to "100%" and left it looking stuck.
        // A terminal state is final.
        guard !item.state.isTerminal else { return }
        item.state = .running(fraction: min(max(fraction, 0), 1))
        inFlightBytes = Int64(Double(max(item.originalSize, 1)) * min(max(fraction, 0), 1))
        recomputeProgress()
    }

    private func recomputeProgress() {
        guard totalBytes > 0 else { progress = 1; return }
        progress = min(1, Double(finishedBytes + inFlightBytes) / Double(totalBytes))
    }

    private func cleanUp() {
        for folder in scratch { try? FileManager.default.removeItem(at: folder) }
        scratch = []
    }
}
