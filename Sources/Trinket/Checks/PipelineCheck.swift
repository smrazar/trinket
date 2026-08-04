import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The end-to-end check: real files on disk, through analyse → plan → run, asserting on what
/// actually lands in the output folder. Every other check tests one piece in isolation; this one
/// is the only thing that proves the pieces are wired to each other.
@MainActor
enum PipelineCheck {

    static func run() async {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "trinket-pipeline-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        // Main-actor bound, so it runs here rather than in the synchronous suite.
        Defaults.selfCheck()
        ScrubReport.selfCheck()   // reads Defaults.Factory, so it is main-actor bound too

        await looseFilesShrinkAndScrub(in: root)
        await archiveRoundTrip(in: root)
        await archiveDroppedAlongsideLooseFiles(in: root)
        await unsupportedFilesSurvive(in: root)
        await splitOpenDeliveryArrivesWhole()

        discardScratchStores()
        // Deliberately not asserted here. A live `UserDefaults` suite cannot be reliably deleted
        // by the process that owns it: `removePersistentDomain` empties the plist but leaves the
        // file, and unlinking it just means cfprefsd writes it back when the process exits. What
        // *is* fixed is the unbounded part — one fixed suite name instead of a fresh UUID per
        // check, so a run leaves at most two files rather than one per check. `package-app.sh`
        // clears them after the check exits, which is the only place it works.
        assert(scratchSuites.isEmpty, "a scratch store was handed out and never discarded")
    }

    /// A multi-file *Open With* reaches `application(_:open:)` in more than one call — fourteen
    /// files arrived as thirteen and then one. Each call used to start its own batch, so the last
    /// delivery reset the ones before it and the missing files were never reported, only absent.
    /// The inbox coalesces a burst into one batch; this is the check that says so.
    private static func splitOpenDeliveryArrivesWhole() async {
        let inbox = FileInbox.shared
        _ = inbox.drain()

        let first = (1...13).map { URL(fileURLWithPath: "/tmp/trinket-check/photo\($0).jpg") }
        let second = [URL(fileURLWithPath: "/tmp/trinket-check/clip.mp4")]
        inbox.deliver(first)
        inbox.deliver(second)

        // Nothing is published while the burst is still arriving.
        assert(inbox.pending.isEmpty, "the inbox published a half-delivered batch")

        try? await Task.sleep(for: FileInbox.settle + .milliseconds(300))
        assert(inbox.pending.count == 14,
               "a split delivery lost files: \(inbox.pending.count) of 14 arrived")
        assert(inbox.pending.last?.pathExtension == "mp4",
               "the last delivery of a burst was dropped — that is exactly the shipped bug")
        _ = inbox.drain()
        assert(inbox.pending.isEmpty, "draining must leave the inbox empty")
    }

    /// The bug this check exists for: a zip dropped *alongside* a few photos passed straight
    /// through at full size, because the analyser only opened an archive when it was the only
    /// thing dropped. The zip is the case the app exists for — it must be opened however it
    /// arrives. Loose files dropped with it stay loose: an archive in, an archive out.
    private static func archiveDroppedAlongsideLooseFiles(in root: URL) async {
        let inside = root.appending(path: "mixed-inside", directoryHint: .isDirectory)
        let source = root.appending(path: "mixed", directoryHint: .isDirectory)
        let output = root.appending(path: "mixed-out", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        for index in 0..<2 { _ = writePhoto(named: "packed-\(index).jpg", into: inside, pixels: 1800) }
        guard let archive = try? ArchivePass.bundle(inside, named: "album", level: 6, into: source),
              let loose = writePhoto(named: "loose.jpg", into: source, pixels: 1600) else {
            assertionFailure("could not stage the mixed drop")
            return
        }
        let archiveSize = (try? FileManager.default
            .attributesOfItem(atPath: archive.path)[.size] as? NSNumber)??.int64Value ?? 0

        // The order matters: the archive is not first, so a rule keyed on "the only item" or
        // "the first item" would also miss it.
        let analysis = Analyser.analyse([loose, archive], unpackArchives: true)
        defer { for used in analysis.unpackedRoots { try? FileManager.default.removeItem(at: used) } }

        assert(analysis.droppedContainers == [archive],
               "a zip dropped next to a photo must still be opened")
        assert(analysis.items.count == 3, "expected the loose photo plus two entries, got \(analysis.items.count)")
        assert(analysis.items.filter { $0.container != nil }.count == 2)
        assert(analysis.items.contains { $0.container == nil && $0.url == loose })

        let batch = Batch()
        batch.items = analysis.items.map { Item(url: $0.url, container: $0.container) }

        var input = PlanInput(files: analysis.facts, hasFFmpeg: Shell.hasFFmpeg)
        input.droppedArchive = true
        input.archiveEntryCount = analysis.archiveEntryCount
        let plan = Planner.propose(input)

        let defaults = Defaults(store: scratchStore())
        defaults.outputFolderPath = output.path
        defaults.outputLocation = .folder     // this case is about folder routing, not location
        let runner = Runner()
        runner.run(batch: batch, plan: plan, defaults: defaults)
        await settle(runner)

        assert(runner.phase == .finished)

        // The entries genuinely shrank rather than passing through.
        for item in batch.items where item.container != nil {
            assert(item.state == .done, "\(item.name) inside the zip ended \(item.state)")
            assert(item.outputSize < item.originalSize,
                   "\(item.name) inside the zip did not shrink")
        }

        // The archive comes back as an archive, and a smaller one.
        guard let bundled = runner.bundleURL else {
            assertionFailure("the archive was opened but never repacked")
            return
        }
        assert(ArchivePass.peek(bundled).count == 2, "the repacked archive lost an entry")
        let bundledSize = (try? FileManager.default
            .attributesOfItem(atPath: bundled.path)[.size] as? NSNumber)??.int64Value ?? 0
        assert(bundledSize < archiveSize,
               "the repacked archive is not smaller: \(archiveSize) → \(bundledSize)")

        // …and the loose photo stays loose. Zipping something the user did not hand us zipped
        // would be a surprise.
        let looseItem = batch.items.first { $0.container == nil }
        assert(looseItem?.state == .done)
        assert(looseItem?.outputURL?.deletingLastPathComponent().path == output.path,
               "a loose file must land in the output folder, not inside the archive")

        await besideTheOriginal(in: root)
        await twoArchivesStaySeparate(in: root)
        await videoInsideAnArchiveShrinks(in: root)
    }

    /// Two archives dropped together must come back as **two** archives, each holding only its
    /// own entries. The staging is per-container and the logic is symmetric with one archive, but
    /// "symmetric so it must work" is how a batch ends up with everything in one zip.
    private static func twoArchivesStaySeparate(in root: URL) async {
        let output = root.appending(path: "two-out", directoryHint: .isDirectory)
        var archives: [URL] = []
        for name in ["alpha", "beta"] {
            let staging = root.appending(path: "two-\(name)", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            _ = writePhoto(named: "\(name)-1.jpg", into: staging, pixels: 1400)
            _ = writePhoto(named: "\(name)-2.jpg", into: staging, pixels: 1400)
            guard let archive = try? ArchivePass.bundle(staging, named: name, level: 6, into: root)
            else { assertionFailure("could not stage \(name).zip"); return }
            archives.append(archive)
        }

        let analysis = Analyser.analyse(archives, unpackArchives: true)
        defer { for used in analysis.unpackedRoots { try? FileManager.default.removeItem(at: used) } }
        assert(analysis.droppedContainers.count == 2, "both archives must be opened")
        assert(analysis.items.count == 4)
        assert(analysis.droppedContainer == nil, "two containers means no single header name")

        let batch = Batch()
        batch.items = analysis.items.map { Item(url: $0.url, container: $0.container) }

        var input = PlanInput(files: analysis.facts, hasFFmpeg: Shell.hasFFmpeg)
        input.droppedArchive = true
        input.archiveEntryCount = analysis.archiveEntryCount
        let plan = Planner.propose(input)

        let defaults = Defaults(store: scratchStore())
        defaults.outputFolderPath = output.path
        defaults.outputLocation = .folder
        let runner = Runner()
        runner.run(batch: batch, plan: plan, defaults: defaults)
        await settle(runner)

        assert(runner.phase == .finished)
        let produced = ArchivePass.walk(output).filter { $0.pathExtension == "zip" }
        assert(produced.count == 2,
               "two archives in must be two archives out, got \(produced.map(\.lastPathComponent))")
        for archive in produced {
            let entries = ArchivePass.peek(archive)
            assert(entries.count == 2, "\(archive.lastPathComponent) holds \(entries.count) entries, want 2")
            // Each archive holds only its own — no cross-contamination between staging folders.
            let stem = archive.lastPathComponent.hasPrefix("alpha") ? "alpha" : "beta"
            assert(entries.allSatisfy { $0.contains(stem) },
                   "\(archive.lastPathComponent) picked up another archive's entries: \(entries)")
        }
    }

    /// A video *inside* an archive must be re-encoded like any other file. It was not: the runner
    /// gated on "can this kind shrink inside an archive?", which only allowed images — a rule
    /// inherited from an older engine that could only rewrite images in place. Here every entry is
    /// unpacked to disk first, so the container it arrived in changes nothing.
    private static func videoInsideAnArchiveShrinks(in root: URL) async {
        guard let ffmpeg = Shell.ffmpeg else { return }   // no encoder in this build, nothing to prove

        let inside = root.appending(path: "vid-inside", directoryHint: .isDirectory)
        let output = root.appending(path: "vid-out", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)

        // Two seconds of noise at a deliberately wasteful bitrate, so there is real room to shrink.
        let clip = inside.appending(path: "clip.mp4")
        guard (try? Shell.require(ffmpeg, [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc=size=640x480:rate=30:duration=2",
            "-c:v", "libx264", "-crf", "5", "-preset", "ultrafast", clip.path,
        ])) != nil else {
            assertionFailure("could not synthesise the probe video")
            return
        }
        _ = writePhoto(named: "still.jpg", into: inside, pixels: 1200)

        guard let archive = try? ArchivePass.bundle(inside, named: "clips", level: 6, into: root) else {
            assertionFailure("could not stage the video archive")
            return
        }

        let analysis = Analyser.analyse([archive], unpackArchives: true)
        defer { for used in analysis.unpackedRoots { try? FileManager.default.removeItem(at: used) } }

        let batch = Batch()
        batch.droppedContainer = archive
        batch.items = analysis.items.map { Item(url: $0.url, container: $0.container) }

        var input = PlanInput(files: analysis.facts, hasFFmpeg: true)
        input.droppedArchive = true
        input.archiveEntryCount = analysis.archiveEntryCount
        let plan = Planner.propose(input)
        assert(plan.lanes.contains { $0.kind == .video && $0.shrink != nil },
               "the plan must contain a video stage when ffmpeg is present")

        let defaults = Defaults(store: scratchStore())
        defaults.outputFolderPath = output.path
        defaults.outputLocation = .folder
        let runner = Runner()
        runner.run(batch: batch, plan: plan, defaults: defaults)
        await settle(runner, seconds: 120)

        assert(runner.phase == .finished)
        guard let video = batch.items.first(where: { $0.kind == .video }) else {
            assertionFailure("the video entry vanished from the batch")
            return
        }
        assert(video.state == .done,
               "a video inside an archive must be converted, not passed through — got \(video.state)")
        assert(video.outputSize > 0 && video.outputSize < video.originalSize,
               "the video inside the archive did not shrink: \(video.originalSize) → \(video.outputSize)")

        // And it is still in the repacked archive, still playable.
        guard let bundled = runner.bundleURL else {
            assertionFailure("the archive was not repacked")
            return
        }
        assert(ArchivePass.peek(bundled).contains { $0.hasSuffix(".mp4") },
               "the repacked archive lost its video")
    }

    /// "Beside the original" writes into the source's own folder rather than the output folder.
    private static func besideTheOriginal(in root: URL) async {
        let source = root.appending(path: "beside", directoryHint: .isDirectory)
        let unused = root.appending(path: "beside-unused", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        guard let photo = writePhoto(named: "in-place.jpg", into: source, pixels: 1600) else {
            assertionFailure("could not stage the beside-the-original probe")
            return
        }

        let analysis = Analyser.analyse([photo], unpackArchives: true)
        let batch = Batch()
        batch.items = analysis.items.map { Item(url: $0.url, container: $0.container) }
        let plan = Planner.propose(PlanInput(files: analysis.facts, hasFFmpeg: Shell.hasFFmpeg))

        let defaults = Defaults(store: scratchStore())
        defaults.outputFolderPath = unused.path
        defaults.outputLocation = .besideOriginal
        let runner = Runner()
        runner.run(batch: batch, plan: plan, defaults: defaults)
        await settle(runner)

        assert(runner.phase == .finished)
        let produced = batch.items.first?.outputURL
        assert(produced?.deletingLastPathComponent().path == source.path,
               "beside-the-original must write next to the source, got \(produced?.path ?? "nothing")")
        // The original is still there — a result landing beside it must not overwrite it.
        assert(FileManager.default.fileExists(atPath: photo.path))
        assert(produced != photo, "the result overwrote the original file")

        // A read-only source folder falls back rather than failing the run.
        let readOnly = Runner.looseDestination(for: URL(filePath: "/System/Library/CoreServices/x.jpg"),
                                               location: .besideOriginal, fallback: unused)
        assert(readOnly == unused, "an unwritable source folder must fall back to the output folder")
    }

    /// The common case: photos land, the plan is pre-answered, one Run produces smaller files
    /// with their GPS gone.
    private static func looseFilesShrinkAndScrub(in root: URL) async {
        let source = root.appending(path: "loose", directoryHint: .isDirectory)
        let output = root.appending(path: "loose-out", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        var originals: [URL] = []
        for index in 0..<3 {
            if let url = writePhoto(named: "photo-\(index).jpg", into: source, pixels: 2400) {
                originals.append(url)
            }
        }
        guard originals.count == 3 else { assertionFailure("could not stage the probe photos"); return }

        let analysis = Analyser.analyse(originals, unpackArchives: true)
        assert(analysis.items.count == 3)
        assert(analysis.report.findings.contains { $0.category == .location },
               "the analyser must find the GPS before the run, or the user cannot verify removal")

        let batch = Batch()
        batch.items = analysis.items.map { seed in
            let item = Item(url: seed.url, container: seed.container)
            item.findings = seed.findings
            return item
        }

        var input = PlanInput(files: analysis.facts, hasFFmpeg: Shell.hasFFmpeg)
        input.defaults = PlanDefaults()
        let plan = Planner.propose(input)
        assert(plan.lanes.count == 1 && plan.lanes[0].kind == .image)
        assert(plan.lanes[0].shrink?.face == .reduce)
        assert(!plan.bundle.enabled, "loose files in, loose files out")

        let defaults = Defaults(store: scratchStore())
        defaults.outputFolderPath = output.path
        defaults.outputLocation = .folder
        let runner = Runner()
        runner.run(batch: batch, plan: plan, defaults: defaults)
        await settle(runner)

        assert(runner.phase == .finished, "the run did not finish: \(runner.phase)")
        for item in batch.items {
            assert(item.state == .done, "\(item.name) ended \(item.state)")
            assert(item.outputSize > 0 && item.outputSize < item.originalSize,
                   "\(item.name) did not get smaller: \(item.originalSize) → \(item.outputSize)")
            guard let produced = item.outputURL else { assertionFailure("no output URL"); continue }
            assert(FileManager.default.fileExists(atPath: produced.path),
                   "the run reported success but wrote no file")
            // The guarantee, checked on the bytes that actually landed.
            let remaining = MetadataPass.inspect(produced, kind: .image)
            assert(!remaining.contains { $0.category == .location },
                   "\(item.name) still carries GPS after a share-safe run")
            assert(!remaining.contains { $0.category == .embeddedThumbnail },
                   "\(item.name) still carries a thumbnail of the uncropped original")
        }
        // And the originals are untouched, because the default is Keep.
        for original in originals {
            assert(FileManager.default.fileExists(atPath: original.path),
                   "the default must never touch the user's original file")
        }
    }

    /// Drop one zip: it opens, the photos inside shrink, and it repacks into one archive.
    private static func archiveRoundTrip(in root: URL) async {
        let staging = root.appending(path: "zip-staging", directoryHint: .isDirectory)
        let output = root.appending(path: "zip-out", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        for index in 0..<2 { _ = writePhoto(named: "inside-\(index).jpg", into: staging, pixels: 1800) }
        // A file trinket cannot shrink inside an archive — it must still come out the far side.
        try? Data(repeating: 9, count: 4096).write(to: staging.appending(path: "notes.bin"))

        guard let archive = try? ArchivePass.bundle(staging, named: "photos", level: 6, into: root) else {
            assertionFailure("could not stage the probe archive")
            return
        }

        let analysis = Analyser.analyse([archive], unpackArchives: true)
        defer { for root in analysis.unpackedRoots { try? FileManager.default.removeItem(at: root) } }
        assert(analysis.droppedContainer == archive)
        assert(analysis.items.count == 3, "the archive's entries did not all survive analysis")

        let batch = Batch()
        batch.droppedContainer = archive
        batch.items = analysis.items.map { Item(url: $0.url, container: $0.container) }

        var input = PlanInput(files: analysis.facts, hasFFmpeg: Shell.hasFFmpeg)
        input.droppedArchive = true
        input.archiveEntryCount = analysis.archiveEntryCount
        let plan = Planner.propose(input)
        assert(plan.lanes.first?.unpack?.enabled == true, "an archive must default to Unpack it")
        assert(plan.bundle.enabled, "an opened archive must converge on one bundle")

        let defaults = Defaults(store: scratchStore())
        defaults.outputFolderPath = output.path
        defaults.outputLocation = .folder
        let runner = Runner()
        runner.run(batch: batch, plan: plan, defaults: defaults)
        await settle(runner)

        assert(runner.phase == .finished)
        guard let bundled = runner.bundleURL else {
            assertionFailure("the run produced no archive")
            return
        }
        assert(FileManager.default.fileExists(atPath: bundled.path))
        assert(bundled.lastPathComponent.hasPrefix("photos-trinket"),
               "the result should be named after what the user dropped, got \(bundled.lastPathComponent)")

        // Every entry that went in comes out — including the one nothing could be done to.
        let entries = ArchivePass.peek(bundled)
        assert(entries.count == 3,
               "the repacked archive lost an entry: \(entries)")
        assert(entries.contains { $0.hasSuffix("notes.bin") },
               "a file trinket cannot shrink was dropped from the archive instead of carried through")

        let carried = batch.items.first { $0.name == "notes.bin" }
        assert(carried?.state == .passedThrough(reason: "passes through unchanged"),
               "an unshrinkable entry must read as passed-through, not failed")

        // No scratch folder survives the run.
        assert(!FileManager.default.fileExists(atPath: root.appending(path: "trinket-stage").path))
    }

    /// A file nothing can be done to still ends the run cleanly, in amber rather than red.
    private static func unsupportedFilesSurvive(in root: URL) async {
        let source = root.appending(path: "odd", directoryHint: .isDirectory)
        let output = root.appending(path: "odd-out", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let blob = source.appending(path: "mystery.dat")
        try? Data(repeating: 3, count: 2048).write(to: blob)
        // A file with a real image extension but no image inside it — the failure path.
        let broken = source.appending(path: "broken.jpg")
        try? Data("not an image".utf8).write(to: broken)

        let analysis = Analyser.analyse([blob, broken], unpackArchives: true)
        let batch = Batch()
        batch.items = analysis.items.map { Item(url: $0.url, container: $0.container) }

        let plan = Planner.propose(PlanInput(files: analysis.facts, hasFFmpeg: Shell.hasFFmpeg))
        let defaults = Defaults(store: scratchStore())
        defaults.outputFolderPath = output.path
        let runner = Runner()
        runner.run(batch: batch, plan: plan, defaults: defaults)
        await settle(runner)

        assert(runner.phase == .finished, "one broken file must not stall the whole run")

        let mystery = batch.items.first { $0.name == "mystery.dat" }
        assert(mystery?.state.isFailure == false,
               "a file trinket was never going to convert is amber, not red")
        let brokenItem = batch.items.first { $0.name == "broken.jpg" }
        assert(brokenItem?.state.isFailure == true,
               "a file that claimed to be an image and was not is a real failure")
        assert(brokenItem?.savings == nil && brokenItem?.sizePair == nil,
               "a failed row must not print a saving")
    }

    // MARK: - Plumbing

    /// Waits for the runner to leave its running states, with a ceiling so a hang fails the
    /// check rather than blocking the build forever.
    private static func settle(_ runner: Runner, seconds: Int = 60) async {
        for _ in 0..<(seconds * 20) {
            if !runner.isRunning, runner.phase != .analysing { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        assertionFailure("the runner never finished — it is stuck in \(runner.phase)")
    }

    /// A throwaway defaults suite, so a check never writes into the user's real preferences.
    ///
    /// **Throwaway means it has to be thrown away.** A suite is a plist under
    /// `~/Library/Preferences` that outlives the process, so handing one out and forgetting it
    /// leaves litter on every run — and the packaging script runs the suite on every build.
    private static func scratchStore() -> UserDefaults {
        // One fixed name, wiped before each hand-out, rather than a UUID per call: a suite is a
        // file in ~/Library/Preferences, and 366 of them had accumulated from UUID names.
        let suite = "trinket.check.scratch"
        guard let store = UserDefaults(suiteName: suite) else { return .standard }
        store.removePersistentDomain(forName: suite)
        if !scratchSuites.contains(where: { $0.0 == suite }) { scratchSuites.append((suite, store)) }
        return store
    }

    private nonisolated(unsafe) static var scratchSuites: [(String, UserDefaults)] = []

    /// Removes every suite handed out by `scratchStore()`. Called at the end of `run()`.
    private static func discardScratchStores() {
        for (suite, store) in scratchSuites {
            Defaults.discardSuite(suite, from: store)
        }
        scratchSuites = []
    }

    /// A JPEG with GPS, a camera serial and an embedded thumbnail — the three things the scrub
    /// promises to remove.
    private static func writePhoto(named name: String, into folder: URL, pixels: Int) -> URL? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }

        let width = pixels, height = pixels * 3 / 4
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        // Deterministic noise: compressible enough to be a realistic photo, varied enough that
        // the encoder cannot cheat.
        var seed: UInt64 = 0x2545f4914f6cdd1d
        for band in 0..<120 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let value = Double((seed >> 33) & 0xff) / 255.0
            context.setFillColor(red: value, green: 1 - value, blue: value * 0.5, alpha: 1)
            context.fill(CGRect(x: 0, y: Double(band) * Double(height) / 120,
                                width: Double(width), height: Double(height) / 120 + 1))
        }
        guard let image = context.makeImage() else { return nil }

        let properties: [CFString: Any] = [
            kCGImageDestinationEmbedThumbnail: true,
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 51.5074,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 0.1278,
                kCGImagePropertyGPSLongitudeRef: "W",
            ] as [CFString: Any],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifBodySerialNumber: "SN-PIPELINE",
                kCGImagePropertyExifDateTimeOriginal: "2026:08:03 12:00:00",
            ] as [CFString: Any],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "trinket",
                kCGImagePropertyTIFFSoftware: "self-check",
            ] as [CFString: Any],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? url : nil
    }
}
