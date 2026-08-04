import Foundation

/// What the analyser learned about one file. A plain value, so the planner never touches the
/// filesystem and its assertions run without an app.
struct FileFact: Equatable {
    var kind: Kind
    var size: Int64
    /// JPEG, HEIC, MP4, PDF, MP3 — data with no redundancy left to squeeze.
    var isAlreadyCompressed: Bool = false
    /// Longest edge in pixels, for images. 0 when unknown or not an image.
    var longestEdge: Int = 0
}

/// Everything the planner needs, and nothing it doesn't.
struct PlanInput: Equatable {
    var files: [FileFact] = []
    /// The user dropped a container, so the plan may open it.
    var droppedArchive = false
    var archiveEntryCount = 0
    var defaults = PlanDefaults()
    var hasFFmpeg = false
}

/// Turns facts into a proposed plan. Pure: same input, same Blueprint, no I/O, no app.
enum Planner {
    /// Beyond this share of already-compressed bytes, a high compression level buys nothing and
    /// costs a great deal of time. Measured case: a 145.3 MB photo zip came out at 146.7 MB.
    private static let incompressibleThreshold = 0.7

    static func propose(_ input: PlanInput) -> Blueprint {
        var plan = Blueprint(scrub: input.defaults.scrubLevel)
        guard !input.files.isEmpty else { return plan }

        let unpack = input.droppedArchive
            ? UnpackStage(enabled: true, entryCount: input.archiveEntryCount)
            : nil

        // One lane per kind actually present, in a stable order so the sidebar does not reshuffle
        // when a file is added.
        var isFirstLane = true
        for kind in Kind.allCases {
            let files = input.files.filter { $0.kind == kind }
            guard !files.isEmpty else { continue }

            // The Unpack stage belongs to the drop, not to a kind. It rides on the first lane so
            // the sidebar draws it once, at the top, where the analyser put it.
            let laneUnpack = isFirstLane ? unpack : nil
            isFirstLane = false

            guard let shrink = shrinkStage(for: kind, files: files, input: input) else {
                plan.caveats.append(caveat(for: kind, count: files.count, input: input))
                plan.lanes.append(Lane(kind: kind, itemCount: files.count,
                                       unpack: laneUnpack, shrink: nil))
                continue
            }
            plan.lanes.append(Lane(kind: kind, itemCount: files.count,
                                   unpack: laneUnpack, shrink: shrink))
        }

        // Everything converges on one Bundle — but only when we opened a container in the first
        // place. A user who dropped loose files gets loose files back.
        if input.droppedArchive {
            plan.bundle = bundleStage(for: input)
            if plan.bundle.isFastPath {
                plan.caveats.append(.init(
                    text: "Contents are already compressed, so the zip is written at speed rather than squeezed further — the size is the same either way.",
                    isNotYet: false))
            }
        }

        return plan
    }

    /// The plan a drop *would* get, with nothing dropped yet — what the sidebar shows on an empty
    /// window so its controls are reachable before a file arrives. One lane per kind this build
    /// can act on, so every setting has somewhere to live.
    static func preview(_ defaults: PlanDefaults, hasFFmpeg: Bool) -> Blueprint {
        var kinds: [Kind] = [.image, .document, .audio]
        if hasFFmpeg { kinds.append(.video) }

        var plan = Blueprint(scrub: defaults.scrubLevel)
        plan.isPreview = true
        plan.lanes = kinds.compactMap { kind in
            let input = PlanInput(defaults: defaults, hasFFmpeg: hasFFmpeg)
            guard let stage = shrinkStage(for: kind, files: [], input: input) else { return nil }
            return Lane(kind: kind, itemCount: 0, unpack: nil, shrink: stage)
        }
        return plan
    }

    // MARK: - Stages

    private static func shrinkStage(for kind: Kind, files: [FileFact], input: PlanInput) -> ShrinkStage? {
        let defaults = input.defaults
        switch kind {
        case .image:
            var stage = ShrinkStage(kind: .image,
                                    target: .image(defaults.imageFormat),
                                    quality: defaults.quality,
                                    longestEdge: defaults.longestEdge,
                                    targetKilobytes: defaults.targetKilobytes)
            // Never upscale. If everything in the drop is already smaller than the cap, the cap
            // is noise in the summary line — drop it rather than promise a resize that won't run.
            let widest = files.map(\.longestEdge).max() ?? 0
            if widest > 0, stage.longestEdge >= widest { stage.longestEdge = 0 }
            return stage

        case .document:
            return ShrinkStage(kind: .document,
                               target: .document(defaults.documentFormat),
                               quality: defaults.quality,
                               longestEdge: 0,
                               targetKilobytes: 0)

        case .audio:
            var target = defaults.audioFormat
            // Offering a format we cannot write is worse than not offering it.
            if target.needsFFmpeg, !input.hasFFmpeg { target = .keep }
            return ShrinkStage(kind: .audio, target: .audio(target),
                               quality: defaults.quality, longestEdge: 0, targetKilobytes: 0)

        case .video:
            // Every video path is ffmpeg. Without it the stage is absent, not disabled, and the
            // caveat says so in as many words.
            guard input.hasFFmpeg else { return nil }
            return ShrinkStage(kind: .video, target: .video(defaults.videoFormat),
                               quality: defaults.quality, longestEdge: 0, targetKilobytes: 0)

        case .archive:
            // A nested archive is left alone. Recursing into archives inside archives is a
            // different feature with its own failure modes.
            return nil

        case .other:
            return nil
        }
    }

    private static func caveat(for kind: Kind, count: Int, input: PlanInput) -> Blueprint.Caveat {
        switch kind {
        case .video where !input.hasFFmpeg:
            // The only reason a video is ever skipped now: this build shipped without ffmpeg.
            return .init(text: "\(kind.counted(count)) passes through unchanged — this build has no video encoder.",
                         isNotYet: true)
        case .archive:
            return .init(text: "\(kind.counted(count)) inside stays packed — trinket opens one layer, not two.")
        default:
            return .init(text: "\(kind.counted(count)) passes through unchanged.")
        }
    }

    private static func bundleStage(for input: PlanInput) -> BundleStage {
        let total = input.files.reduce(Int64(0)) { $0 + $1.size }
        guard total > 0 else { return BundleStage(enabled: true, level: 6) }
        let compressed = input.files
            .filter(\.isAlreadyCompressed)
            .reduce(Int64(0)) { $0 + $1.size }
        let share = Double(compressed) / Double(total)
        return BundleStage(enabled: true, level: share > incompressibleThreshold ? 1 : 6)
    }

    // MARK: - Self-check

    static func selfCheck() {
        let photo = FileFact(kind: .image, size: 6_200_000, isAlreadyCompressed: true, longestEdge: 4032)
        let video = FileFact(kind: .video, size: 75_400_000, isAlreadyCompressed: true)
        let pdf = FileFact(kind: .document, size: 4_100_000, isAlreadyCompressed: true)

        // An empty drop proposes nothing rather than an empty scaffold.
        assert(Planner.propose(PlanInput()).isEmpty)

        // The flagship case: a photo zip. Unpack → Reduce → Bundle, and the bundle takes the fast
        // path because the contents cannot be recompressed.
        let zip = PlanInput(files: Array(repeating: photo, count: 22),
                            droppedArchive: true, archiveEntryCount: 41,
                            defaults: PlanDefaults(), hasFFmpeg: true)
        let zipPlan = Planner.propose(zip)
        assert(zipPlan.lanes.count == 1 && zipPlan.lanes[0].kind == .image)
        assert(zipPlan.lanes[0].unpack?.enabled == true, "an archive defaults to Unpack it")
        assert(zipPlan.lanes[0].unpack?.summary == "Open it · 41 items")
        assert(zipPlan.lanes[0].shrink?.face == .reduce, "keep format means the Reduce face")
        assert(zipPlan.bundle.enabled && zipPlan.bundle.isFastPath,
               "22 JPEGs cannot be recompressed — level 9 would only make it slower")
        assert(zipPlan.caveats.contains { $0.text.contains("already compressed") })
        assert(zipPlan.stepCount == 3)

        // Loose files get loose files back — no bundle nobody asked for.
        let loose = PlanInput(files: [photo, photo], hasFFmpeg: true)
        assert(!Planner.propose(loose).bundle.enabled)

        // Mixed drop: one lane per kind, in a stable order, converging on the shared bundle.
        let mixed = PlanInput(files: [photo, video, pdf], droppedArchive: true,
                              archiveEntryCount: 3, hasFFmpeg: true)
        let mixedPlan = Planner.propose(mixed)
        assert(mixedPlan.isMixed && mixedPlan.lanes.count == 3)
        assert(mixedPlan.lanes.map(\.kind) == [.image, .document, .video],
               "lane order follows Kind.allCases so the sidebar never reshuffles")
        assert(mixedPlan.lanes[0].unpack != nil, "Unpack is drawn once, on the first lane")
        assert(mixedPlan.lanes[1].unpack == nil && mixedPlan.lanes[2].unpack == nil)

        // No ffmpeg: the video stage is absent, not disabled, and the caveat is an honest amber
        // "not yet" rather than silence or a fake progress bar.
        let noFFmpeg = Planner.propose(PlanInput(files: [photo, video], hasFFmpeg: false))
        let videoLane = noFFmpeg.lanes.first { $0.kind == .video }
        assert(videoLane != nil && videoLane?.shrink == nil)
        // The caveat names the actual reason. It used to say "video shrink is coming", which was
        // true of the old engine and is now false — video works, unless this build shipped without
        // an encoder. A caveat that describes a limitation the app no longer has is a lie.
        assert(noFFmpeg.caveats.contains { $0.isNotYet && $0.text.contains("no video encoder") })

        // An ffmpeg-only audio format falls back rather than being offered and failing later.
        var mp3Defaults = PlanDefaults()
        mp3Defaults.audioFormat = .mp3
        let audio = FileFact(kind: .audio, size: 8_000_000, isAlreadyCompressed: true)
        let noMP3 = Planner.propose(PlanInput(files: [audio], defaults: mp3Defaults, hasFFmpeg: false))
        assert(noMP3.lanes[0].shrink?.target == .audio(.keep), "cannot offer MP3 with no encoder")
        let withMP3 = Planner.propose(PlanInput(files: [audio], defaults: mp3Defaults, hasFFmpeg: true))
        assert(withMP3.lanes[0].shrink?.target == .audio(.mp3))

        // Never upscale: a drop of small images drops the resize cap instead of promising one.
        let small = FileFact(kind: .image, size: 90_000, longestEdge: 640)
        let smallPlan = Planner.propose(PlanInput(files: [small], hasFFmpeg: true))
        assert(smallPlan.lanes[0].shrink?.longestEdge == 0)
        assert(smallPlan.lanes[0].shrink?.summary == "keep format · 75%",
               "a cap that will never fire must not appear in the summary")

        // A compressible archive keeps a real compression level.
        let text = FileFact(kind: .document, size: 10_000_000, isAlreadyCompressed: false)
        let textZip = Planner.propose(PlanInput(files: [text], droppedArchive: true,
                                                archiveEntryCount: 1, hasFFmpeg: true))
        assert(!textZip.bundle.isFastPath, "compressible contents deserve real compression")

        // The empty-window preview: one lane per kind this build can act on, so every control
        // has somewhere to live before a file is dropped. It must never look like a real plan.
        let preview = Planner.preview(PlanDefaults(), hasFFmpeg: true)
        assert(preview.isPreview)
        assert(!preview.isEmpty, "the preview must offer controls, not an empty sidebar")
        assert(preview.lanes.contains { $0.kind == .image })
        assert(preview.lanes.allSatisfy { $0.itemCount == 0 })
        assert(preview.lanes[0].title == "Photos", "a zero-item lane must name the kind, not count to zero")
        assert(!preview.bundle.enabled, "there is nothing to bundle until something is dropped")
        // Without ffmpeg the video lane is absent from the preview too — the controls shown are
        // only ever the ones this build can honour.
        assert(!Planner.preview(PlanDefaults(), hasFFmpeg: false).lanes.contains { $0.kind == .video })

        // The scrub level is carried from the user's defaults, not re-decided per drop.
        var quiet = PlanDefaults()
        quiet.scrubLevel = .nothingButPixels
        assert(Planner.propose(PlanInput(files: [photo], defaults: quiet)).scrub == .nothingButPixels)
    }
}
