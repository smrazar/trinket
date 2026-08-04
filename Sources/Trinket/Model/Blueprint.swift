import Foundation

/// The plan the app proposes. Files land, the analyser produces one of these, and the left
/// sidebar *is* it: one section per stage, in the order the analyser chose, every decision
/// pre-answered. Stages that do not apply are absent, not disabled.
///
/// A mixed drop becomes several lanes running in parallel and converging on one Bundle. A
/// single-kind drop is one lane, and the sidebar draws its stages without a lane header.

// MARK: - Target format

/// The format a lane converts to. Only image formats are ever offered for an image — the type
/// system enforces that here rather than a menu builder remembering to.
enum TargetFormat: Equatable {
    case image(ImageFormat)
    case document(DocumentFormat)
    case audio(AudioFormat)
    case video(VideoFormat)
    /// `other` files have no format to change. They pass through.
    case passthrough

    /// True when the format is unchanged — which is exactly when the stage wears its Reduce face.
    var isKeep: Bool {
        switch self {
        case .image(let f):    return f == .keep
        case .document(let f): return f == .keep
        case .audio(let f):    return f == .keep
        case .video(let f):    return f == .keep
        case .passthrough:     return true
        }
    }

    var title: String {
        switch self {
        case .image(let f):    return f.title
        case .document(let f): return f.title
        case .audio(let f):    return f.title
        case .video(let f):    return f.title
        case .passthrough:     return "Unchanged"
        }
    }

    var fileExtension: String? {
        switch self {
        case .image(let f):    return f.fileExtension
        case .document(let f): return f.fileExtension
        case .audio(let f):    return f.fileExtension
        case .video(let f):    return f.fileExtension
        case .passthrough:     return nil
        }
    }

    /// Quality only means something for a lossy encoder. When it means nothing the stage hides
    /// the slider rather than showing a control that does nothing.
    var hasQuality: Bool {
        switch self {
        case .image(let f):    return f == .keep || f.isLossy
        case .document:        return true
        case .audio(let f):    return f == .keep || f.isLossy
        case .video:           return true
        case .passthrough:     return false
        }
    }

    /// Longest edge is a pixel notion. Only images have it.
    var hasPixels: Bool {
        if case .image = self { return true }
        return false
    }
}

// MARK: - Stages

/// Open the container first. An archive defaults to "Unpack it" — a user who dropped a zip
/// almost always wants what is inside made smaller, not the zip re-zipped.
struct UnpackStage: Equatable {
    var enabled: Bool = true
    var entryCount: Int = 0

    var summary: String {
        guard enabled else { return "Leave it packed" }
        return entryCount > 0 ? "Open it · \(entryCount) items" : "Open it"
    }
}

/// Reduce and Convert are one stage with two faces. When the format is unchanged it is **Reduce**
/// and owns quality / longest edge / target size. When the format changes it becomes **Convert**,
/// gaining a format picker with the reduction controls nested inside. Never two stages for one
/// image — the engine does a single ImageIO pass, and two stages would imply two.
struct ShrinkStage: Equatable {
    var kind: Kind
    var target: TargetFormat
    /// 0…1.
    var quality: Double = 0.75
    /// Longest edge in pixels; 0 means never resize.
    var longestEdge: Int = 1024
    /// Target file size in KB; 0 means off.
    var targetKilobytes: Int = 0

    enum Face: Equatable { case reduce, convert }

    var face: Face { target.isKeep ? .reduce : .convert }
    var title: String { face == .reduce ? "Reduce" : "Convert" }

    /// The badge beside the stage name in the expanded card.
    var faceNote: String { face == .reduce ? "format unchanged" : "format changes" }

    /// The collapsed one-line decision: `keep format · 75% · 1024px`.
    var summary: String {
        var parts: [String] = []
        parts.append(target.isKeep ? "keep format" : target.title)
        if target.hasQuality { parts.append("\(Int((quality * 100).rounded()))%") }
        if target.hasPixels, longestEdge > 0 { parts.append("\(longestEdge)px") }
        if targetKilobytes > 0 { parts.append("≤ \(Bytes.format(Int64(targetKilobytes) * 1000))") }
        return parts.joined(separator: " · ")
    }
}

/// Everything converges here. One archive out, or none.
struct BundleStage: Equatable {
    var enabled: Bool = false
    var level: Int = 6
    var name: String = "trinket"

    /// Already-compressed data cannot be recompressed. JPEG, MP4 and PDF have no redundancy left,
    /// so level 9 adds container overhead and a great deal of time for nothing — 145.3 MB became
    /// 146.7 MB in the case that prompted this. When the contents are incompressible the planner
    /// drops the level to 1, which produces the same bytes far faster.
    var isFastPath: Bool { level <= 1 }

    var summary: String {
        guard enabled else { return "No archive" }
        // "level 1" reads like a setting someone got wrong. Name the behaviour instead — the
        // caveat beneath explains that the size is the same either way.
        return isFastPath ? "One zip · fast" : "One zip · level \(level)"
    }
}

// MARK: - Lane

/// One kind's path through the plan. A mixed drop has several; they run in parallel.
struct Lane: Identifiable, Equatable {
    var id: Kind { kind }
    var kind: Kind
    var itemCount: Int
    var unpack: UnpackStage?
    var shrink: ShrinkStage?

    /// Lane title for a mixed drop: "22 photos". Single-kind drops draw no lane header.
    /// With no items — the empty-window preview — name the kind rather than counting to zero.
    var title: String { itemCount > 0 ? kind.counted(itemCount) : kind.lane }

    var stageCount: Int { (unpack != nil ? 1 : 0) + (shrink != nil ? 1 : 0) }
}

// MARK: - Blueprint

struct Blueprint: Equatable {
    var lanes: [Lane] = []
    var bundle = BundleStage()
    var scrub: ScrubLevel = .shareSafe
    /// True when this is the "what a drop would get" preview shown on an empty window, rather
    /// than a plan for files that actually exist. The sidebar labels itself accordingly and does
    /// not offer to run it.
    var isPreview = false
    /// What the analyser could not act on, said plainly rather than hidden.
    var caveats: [Caveat] = []

    struct Caveat: Equatable, Identifiable {
        var id: String { text }
        var text: String
        /// Inside an archive, video and document rows pass through unchanged today. Marked amber
        /// and named, never given a fake progress bar.
        var isNotYet: Bool = false
    }

    var isEmpty: Bool { lanes.isEmpty }
    var isMixed: Bool { lanes.count > 1 }

    /// Total stages the header counts: "4 steps".
    var stepCount: Int {
        lanes.reduce(0) { $0 + $1.stageCount } + (bundle.enabled ? 1 : 0)
    }

    var stepLabel: String { "\(stepCount) \(stepCount == 1 ? "step" : "steps")" }

    /// The compact breadcrumb shown above the list at the 720pt minimum width, so guidance
    /// survives when neither sidebar fits: `Unpack › Reduce · 75% · 1024px › Bundle · zip`.
    var breadcrumb: [String] {
        var crumbs: [String] = []
        if lanes.contains(where: { $0.unpack?.enabled == true }) { crumbs.append("Unpack") }
        for lane in lanes {
            guard let shrink = lane.shrink else { continue }
            let prefix = isMixed ? "\(lane.kind.lane): " : ""
            crumbs.append(prefix + shrink.title + " · " + shrink.summary)
        }
        if bundle.enabled { crumbs.append("Bundle · zip") }
        return crumbs
    }

    /// Mutating a stage by lane keeps the UI from reaching into arrays by index.
    mutating func updateShrink(for kind: Kind, _ change: (inout ShrinkStage) -> Void) {
        guard let index = lanes.firstIndex(where: { $0.kind == kind }),
              var shrink = lanes[index].shrink else { return }
        change(&shrink)
        lanes[index].shrink = shrink
    }

    static func selfCheck() {
        // The dual face is derived, never set. Change the format and the stage renames itself.
        var stage = ShrinkStage(kind: .image, target: .image(.keep), quality: 0.75, longestEdge: 1024)
        assert(stage.face == .reduce && stage.title == "Reduce")
        assert(stage.summary == "keep format · 75% · 1024px")
        stage.target = .image(.jpeg)
        assert(stage.face == .convert && stage.title == "Convert",
               "changing the format must change the face — never two stages for one ImageIO pass")
        assert(stage.summary == "JPEG · 75% · 1024px")

        // A lossless target hides the quality slider rather than showing a dead control.
        stage.target = .image(.png)
        assert(!stage.target.hasQuality)
        assert(stage.summary == "PNG · 1024px")

        // Longest edge is a pixel notion — audio must not offer one.
        var audio = ShrinkStage(kind: .audio, target: .audio(.mp3), quality: 0.6, longestEdge: 1024)
        assert(!audio.target.hasPixels)
        assert(audio.summary == "MP3 · 60%", "an audio stage must not print a pixel width")
        audio.targetKilobytes = 250
        assert(audio.summary == "MP3 · 60% · ≤ 250.0 KB")

        // A passthrough lane offers nothing to change.
        let other = ShrinkStage(kind: .other, target: .passthrough)
        assert(other.face == .reduce && !other.target.hasQuality && !other.target.hasPixels)

        // Step count and the breadcrumb agree with the mockups.
        let lane = Lane(kind: .image, itemCount: 22,
                        unpack: UnpackStage(enabled: true, entryCount: 41),
                        shrink: ShrinkStage(kind: .image, target: .image(.keep)))
        var plan = Blueprint(lanes: [lane], bundle: BundleStage(enabled: true, level: 9))
        assert(plan.stepCount == 3 && plan.stepLabel == "3 steps")
        assert(plan.breadcrumb == ["Unpack", "Reduce · keep format · 75% · 1024px", "Bundle · zip"])
        assert(!plan.isMixed)

        // Mixed drops keep their lanes separate — never flattened into one control set.
        plan.lanes.append(Lane(kind: .video, itemCount: 1, unpack: nil,
                               shrink: ShrinkStage(kind: .video, target: .video(.keep))))
        assert(plan.isMixed && plan.stepCount == 4)
        assert(plan.breadcrumb.contains { $0.hasPrefix("Photos: ") },
               "a mixed breadcrumb must name which lane each stage belongs to")

        // updateShrink reaches the right lane and leaves the others alone.
        plan.updateShrink(for: .video) { $0.target = .video(.h264) }
        assert(plan.lanes[1].shrink?.face == .convert)
        assert(plan.lanes[0].shrink?.face == .reduce)

        // A bundle at level 1 is the incompressible-contents path, and names the behaviour rather
        // than printing a number that reads like a mistake.
        assert(BundleStage(enabled: true, level: 1).isFastPath)
        assert(BundleStage(enabled: true, level: 1).summary == "One zip · fast")
        assert(!BundleStage(enabled: true, level: 9).isFastPath)
        assert(BundleStage(enabled: true, level: 9).summary == "One zip · level 9")
        assert(BundleStage(enabled: false).summary == "No archive")
    }
}
