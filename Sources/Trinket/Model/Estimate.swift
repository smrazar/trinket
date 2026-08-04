import Foundation

/// What the sidebar promises before the run: `Est. 65.1 MB smaller · 47%`.
///
/// These are heuristics, and they are labelled "Est." in the UI for that reason. The honest
/// alternative — encoding every file twice to find out — costs exactly as much as doing the job.
/// The run replaces every number here with a measured one as each file lands.
struct Estimate: Equatable {
    var before: Int64 = 0
    var after: Int64 = 0

    var saved: Int64 { max(0, before - after) }
    var percent: Int { Bytes.savings(from: before, to: after) ?? 0 }
    var isWorthShowing: Bool { saved > 0 }

    /// `65.1 MB smaller · 47%`
    var headline: String { "\(Bytes.format(saved)) smaller · \(percent)%" }

    static func of(_ facts: [FileFact], under plan: Blueprint) -> Estimate {
        var estimate = Estimate()
        for fact in facts {
            estimate.before += fact.size
            estimate.after += predict(fact, under: plan)
        }
        return estimate
    }

    /// The predicted output size for one file under this plan.
    static func predict(_ fact: FileFact, under plan: Blueprint) -> Int64 {
        guard let lane = plan.lanes.first(where: { $0.kind == fact.kind }),
              let shrink = lane.shrink else {
            return fact.size  // no stage for this kind — it passes through at full size
        }
        return Int64(Double(fact.size) * ratio(for: fact, under: shrink))
    }

    // ponytail: fixed ratios per (kind, format, quality). Good to roughly ±15% on the sample set,
    // which is enough for a pre-run estimate. Upgrade path if it ever matters: encode one file at
    // the chosen settings and scale the batch by its measured ratio.
    private static func ratio(for fact: FileFact, under shrink: ShrinkStage) -> Double {
        // Resizing dominates everything else — area scales with the square of the edge.
        var scale = 1.0
        if shrink.longestEdge > 0, fact.longestEdge > shrink.longestEdge {
            let linear = Double(shrink.longestEdge) / Double(fact.longestEdge)
            scale = linear * linear
        }

        switch shrink.target {
        case .image(let format):
            // Re-encoding at q75 costs a compressed source about a third; an uncompressed or
            // lossless source loses far more, which is why a PNG screenshot shrinks so hard.
            let base: Double
            switch format {
            case .png, .tiff:
                base = fact.isAlreadyCompressed ? 2.4 : 0.9   // lossless out of lossy is bigger
            case .jpeg, .heic, .keep:
                let quality = shrink.quality
                let floor = format == .heic ? 0.18 : 0.28
                base = fact.isAlreadyCompressed
                    ? floor + (quality * 0.45)
                    : (floor * 0.55) + (quality * 0.30)
            }
            return clamp(base * scale)

        case .document:
            // A PDF's weight is its embedded images, so it tracks the image ratio, damped.
            return clamp((0.45 + shrink.quality * 0.35) * scale)

        case .audio(let format):
            if !format.isLossy && format != .keep { return clamp(1.6) }  // lossless is bigger
            return clamp(0.25 + shrink.quality * 0.45)

        case .video:
            return clamp(0.35 + shrink.quality * 0.40)

        case .passthrough:
            return 1.0
        }
    }

    /// No prediction may claim a file vanishes, and none may claim more than a 4× growth.
    private static func clamp(_ ratio: Double) -> Double { min(max(ratio, 0.02), 4.0) }

    static func selfCheck() {
        let photo = FileFact(kind: .image, size: 6_200_000, isAlreadyCompressed: true, longestEdge: 4032)
        let plan = Planner.propose(PlanInput(files: [photo], hasFFmpeg: true))

        // A 4032px photo capped at 1024px is a 16× area cut — the estimate must reflect that.
        let shrunk = Estimate.predict(photo, under: plan)
        assert(shrunk < photo.size / 4, "capping 4032px to 1024px must predict a large cut")
        assert(shrunk > 0, "no prediction may claim a file vanishes")

        // A kind with no stage passes through at full size, never at a discount.
        let video = FileFact(kind: .video, size: 75_400_000, isAlreadyCompressed: true)
        let noVideo = Planner.propose(PlanInput(files: [photo, video], hasFFmpeg: false))
        assert(Estimate.predict(video, under: noVideo) == video.size,
               "a passed-through file must be estimated at its own size")

        // Lossless out of lossy grows, and the estimate says so rather than promising a saving.
        var toPNG = plan
        toPNG.updateShrink(for: .image) { $0.target = .image(.png); $0.longestEdge = 0 }
        assert(Estimate.predict(photo, under: toPNG) > photo.size,
               "JPEG to PNG makes the file bigger — do not predict a saving")

        // The batch total, and the "no saving to show" case.
        let total = Estimate.of([photo, video], under: noVideo)
        assert(total.before == photo.size + video.size)
        assert(total.isWorthShowing && total.percent > 0)
        let flat = Estimate.of([video], under: noVideo)
        assert(!flat.isWorthShowing && flat.percent == 0,
               "a batch that saves nothing must not print a percentage")

        // Quality moves the number in the direction a user would expect.
        var low = plan, high = plan
        low.updateShrink(for: .image) { $0.quality = 0.3 }
        high.updateShrink(for: .image) { $0.quality = 0.95 }
        assert(Estimate.predict(photo, under: low) < Estimate.predict(photo, under: high))
    }
}
