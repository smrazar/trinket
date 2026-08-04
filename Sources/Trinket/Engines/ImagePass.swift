import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// One ImageIO pass does resize, re-encode and scrub together. That is why Reduce and Convert are
/// one stage with two faces and not two stages — splitting them in the UI would imply two passes,
/// and two passes means decoding, re-encoding and losing quality twice.
enum ImagePass {

    struct Outcome {
        let outputURL: URL
        let size: Int64
        /// The quality actually used, after the content adjustment and any target-size search.
        let quality: Double
    }

    enum Failure: LocalizedError {
        case unreadable(URL)
        case noEncoder(String)
        case writeFailed(URL)

        var errorDescription: String? {
            switch self {
            case .unreadable(let url): return "\(url.lastPathComponent) could not be read as an image."
            case .noEncoder(let name): return "This build cannot write \(name)."
            case .writeFailed(let url): return "Could not write \(url.lastPathComponent)."
            }
        }
    }

    /// Runs the stage over one file. `destination` is the folder the result goes in.
    static func run(_ url: URL,
                    stage: ShrinkStage,
                    scrub: ScrubLevel,
                    into destination: URL) throws -> Outcome {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw Failure.unreadable(url)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]

        // Pick the output type. `keep` means whatever it already was; if ImageIO cannot write
        // that back (a RAW file, say) fall to JPEG rather than fail — the user asked for smaller,
        // not for a format war.
        let outputType = self.outputType(for: url, stage: stage)
        guard let identifier = outputType.identifier as CFString? else {
            throw Failure.noEncoder(outputType.localizedDescription ?? "that format")
        }
        let isLossy = outputType == .jpeg || outputType == .heic

        // Decode at the target size. `WithTransform` bakes the EXIF rotation into the pixels
        // here, which is what lets the scrub declare orientation 1 without the picture ending up
        // sideways. Decoding via the thumbnail path also means a 48-megapixel source is never
        // fully decoded when the target is 1024px.
        let pixelCap = stage.longestEdge > 0 ? stage.longestEdge : sourceLongestEdge(properties)
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, pixelCap),
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(source, 0, decodeOptions as CFDictionary) else {
            throw Failure.unreadable(url)
        }

        // Dropping the colour profile without converting first turns a Display P3 photo muddy —
        // the numbers stay, their meaning changes. Convert to sRGB while the profile still says
        // what they meant.
        if scrub.removes(.colourProfile) {
            image = flattenToSRGB(image) ?? image
        }

        // "Adjust for content" is not a setting any more; it is always on.
        let quality = adjustedQuality(stage.quality, for: image, isLossy: isLossy)

        let originalSize = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.int64Value ?? 0
        let formatChanged = outputType != UTType(filenameExtension: url.pathExtension.lowercased())

        // **Never hand back something bigger** — and that is a ceiling on the *encode*, not only a
        // veto after the fact. Asking for 250 KB when the file is already 166 KB does not mean
        // "166 KB is fine"; it means the file must not grow. Changing the format is the one case
        // where growth is the point: HEIC → JPEG is asked for so that everyone can open it, and a
        // JPEG of the same picture is legitimately larger.
        let ceiling = encodeCeiling(targetKilobytes: stage.targetKilobytes,
                                    originalSize: originalSize,
                                    formatChanged: formatChanged)

        let outputURL = try uniqueDestination(for: url, type: outputType, in: destination)
        let encoded = try encode(image,
                                 as: identifier,
                                 sourceProperties: properties,
                                 scrub: scrub,
                                 quality: quality,
                                 isLossy: isLossy,
                                 ceilingBytes: ceiling)

        // The encode can still come back bigger — a lossless format has no quality to spend, and a
        // lossy one can overshoot even at 0.1. Handing the original bytes back is only allowed when
        // the pass had nothing else to do: if the scrub found something to remove, the file has to
        // be rewritten or the metadata rides along, and a file that is bigger but clean beats one
        // that is smaller and still carries your coordinates.
        let removedSomething = !MetadataPass.inspect(url, kind: .image)
            .filter { scrub.removes($0.category) }.isEmpty

        if Int64(encoded.data.count) >= originalSize, originalSize > 0,
           !formatChanged, !removedSomething {
            try FileManager.default.copyItem(at: url, to: outputURL)
            return Outcome(outputURL: outputURL, size: originalSize, quality: encoded.quality)
        }

        try encoded.data.write(to: outputURL)
        return Outcome(outputURL: outputURL, size: Int64(encoded.data.count), quality: encoded.quality)
    }

    /// The largest the encode may come back, in bytes. `0` means no ceiling.
    ///
    /// Extracted because it is a decision worth arguing about rather than an `&&` clause nobody
    /// reads: the target size and the original size are *both* ceilings, and the smaller wins.
    static func encodeCeiling(targetKilobytes: Int, originalSize: Int64, formatChanged: Bool) -> Int {
        let target = targetKilobytes > 0 ? targetKilobytes * 1000 : 0
        guard !formatChanged, originalSize > 0 else { return target }
        let original = Int(clamping: originalSize)
        return target > 0 ? min(target, original) : original
    }

    // MARK: - Encoding

    private struct Encoded {
        let data: Data
        let quality: Double
    }

    /// Encodes once, or — when a target size is set — walks the quality down until it fits.
    private static func encode(_ image: CGImage,
                               as identifier: CFString,
                               sourceProperties: [CFString: Any],
                               scrub: ScrubLevel,
                               quality: Double,
                               isLossy: Bool,
                               ceilingBytes: Int) throws -> Encoded {
        func attempt(_ quality: Double) throws -> Data {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, identifier, 1, nil) else {
                throw Failure.noEncoder(identifier as String)
            }
            let properties = MetadataPass.imageProperties(keeping: scrub,
                                                          from: sourceProperties,
                                                          quality: quality,
                                                          isLossy: isLossy)
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw Failure.noEncoder(identifier as String)
            }
            return data as Data
        }

        let first = try attempt(quality)
        guard ceilingBytes > 0, isLossy else { return Encoded(data: first, quality: quality) }

        let ceiling = ceilingBytes
        guard first.count > ceiling else { return Encoded(data: first, quality: quality) }

        // Binary search rather than stepping down: eight encodes of a large image is a visible
        // pause, five is not, and the interval halves each time.
        var low = 0.1, high = quality
        var best = Encoded(data: first, quality: quality)
        for _ in 0..<5 {
            let middle = (low + high) / 2
            let data = try attempt(middle)
            if data.count <= ceiling {
                best = Encoded(data: data, quality: middle)
                low = middle          // it fits — try to spend the headroom on quality
            } else {
                high = middle
            }
            if high - low < 0.02 { break }
        }
        // If even quality 0.1 overshoots, hand back the smallest we managed. Saying "could not
        // hit 250 KB" is honest; silently writing a 2 MB file under a 250 KB target is not.
        return best
    }

    // MARK: - Decisions

    private static func outputType(for url: URL, stage: ShrinkStage) -> UTType {
        if case .image(let format) = stage.target, let type = format.utType {
            return type
        }
        let existing = UTType(filenameExtension: url.pathExtension.lowercased())
        let writable = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
        if let existing, writable.contains(existing.identifier) { return existing }
        return .jpeg
    }

    /// The written file's pixel dimensions, read from the header. Used by `{w}`/`{h}` in a
    /// naming pattern.
    static func pixelSize(of url: URL) -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return (0, 0) }
        return (properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
                properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    private static func sourceLongestEdge(_ properties: [CFString: Any]) -> Int {
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        return max(width, height, 1)
    }

    /// Nudges quality per image, always on. A photograph hides JPEG artifacts in its detail; a
    /// screenshot or a flat graphic shows ringing around every hard edge at the same setting. The
    /// cheap proxy for "flat" is how few distinct luminances a 64px thumbnail contains.
    static func adjustedQuality(_ base: Double, for image: CGImage, isLossy: Bool) -> Double {
        guard isLossy else { return base }
        let variety = luminanceVariety(of: image)
        // Under a fifth of the buckets used is a graphic, not a photograph.
        if variety < 0.2 { return min(1.0, base + 0.12) }
        if variety > 0.7 { return max(0.1, base - 0.03) }  // dense detail hides a little more loss
        return base
    }

    /// Fraction of 64 luminance buckets that appear in a 64×64 sample of the image. Cheap, and
    /// it only has to separate "screenshot" from "photograph".
    private static func luminanceVariety(of image: CGImage) -> Double {
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let context = CGContext(data: &pixels,
                                      width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0.5 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var buckets = Set<UInt8>()
        for pixel in pixels { buckets.insert(pixel >> 2) }   // 256 levels into 64 buckets
        return Double(buckets.count) / 64.0
    }

    /// Redraws into sRGB so the numbers still mean the same colours once the profile is gone.
    /// `NSImage.lockFocus()` would allocate at the display's scale — never for deterministic
    /// rendering. A CGContext is told exactly how big it is.
    private static func flattenToSRGB(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil,
                                      width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// A result never silently replaces something already sitting in the output folder.
    static func uniqueDestination(for source: URL, type: UTType, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Keep the source's own extension when the format did not change. `preferredFilenameExtension`
        // answers "jpeg" for JPEG, so a folder of `.jpg` photos would come back renamed for no
        // reason the user asked for.
        let sourceExtension = source.pathExtension.lowercased()
        let ext: String
        if !sourceExtension.isEmpty, UTType(filenameExtension: sourceExtension) == type {
            ext = sourceExtension
        } else {
            ext = type.preferredFilenameExtension ?? sourceExtension
        }
        let base = source.deletingPathExtension().lastPathComponent
        var candidate = folder.appending(path: "\(base).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: "\(base)-\(counter).\(ext)")
            counter += 1
            if counter > 999 { throw Failure.writeFailed(candidate) }
        }
        return candidate
    }

    // MARK: - Self-check

    static func selfCheck() {
        // A flat graphic and a noise field, drawn rather than loaded, so the check needs no files.
        let flat = solid(width: 128, height: 128, gray: 0.5)
        let noisy = noise(width: 128, height: 128)

        let flatVariety = adjustedQuality(0.75, for: flat, isLossy: true)
        let noisyVariety = adjustedQuality(0.75, for: noisy, isLossy: true)
        assert(flatVariety > 0.75, "a flat graphic must be encoded above the base quality — that is where ringing shows")
        assert(noisyVariety <= 0.75, "dense detail hides loss, so it may go below the base")
        assert(adjustedQuality(0.75, for: flat, isLossy: false) == 0.75,
               "a lossless format has no quality to adjust")
        assert(adjustedQuality(0.95, for: flat, isLossy: true) <= 1.0, "quality must never exceed 1")

        // Round-trip a real encode through ImageIO and confirm the scrub actually landed in the
        // written bytes — asserting on the dictionary alone would not prove the file is clean.
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "trinket-selfcheck-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporary) }

        guard let sourceURL = writeProbeImage(into: temporary) else {
            assertionFailure("could not write the probe image the scrub check needs")
            return
        }
        // The probe went in carrying GPS.
        let before = MetadataPass.inspect(sourceURL, kind: .image)
        assert(before.contains { $0.category == .location }, "the probe must start with GPS to be a test")

        let stage = ShrinkStage(kind: .image, target: .image(.jpeg), quality: 0.7, longestEdge: 64)
        guard let outcome = try? run(sourceURL, stage: stage, scrub: .shareSafe, into: temporary) else {
            assertionFailure("the image pass failed on its own probe")
            return
        }
        let after = MetadataPass.inspect(outcome.outputURL, kind: .image)
        assert(!after.contains { $0.category == .location },
               "GPS survived a share-safe scrub — the written file still carries it")
        assert(!after.contains { $0.category == .embeddedThumbnail },
               "an embedded thumbnail survived the scrub")

        // The resize actually happened, and it never upscales.
        if let source = CGImageSourceCreateWithURL(outcome.outputURL as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            assert(sourceLongestEdge(properties) <= 64, "longest edge was not honoured")
        }

        // Never hand back something bigger. Re-encoding an already-optimised image at a higher
        // quality than it was written with grows it, and a "compressor" that grows files is the
        // one thing nobody forgives.
        if let already = try? run(outcome.outputURL,
                                  stage: ShrinkStage(kind: .image, target: .image(.keep),
                                                     quality: 0.95, longestEdge: 0),
                                  scrub: .keepEverything, into: temporary) {
            let source = (try? FileManager.default
                .attributesOfItem(atPath: outcome.outputURL.path)[.size] as? NSNumber)??.int64Value ?? 0
            assert(already.size <= source,
                   "re-encoding an already-small JPEG grew it: \(source) → \(already.size)")
        }

        // The same thing again, but *while scrubbing* — the case that was actually broken in 1.0,
        // where a 166.2 KB photo came back as 222.2 KB because removing one metadata item waived
        // the size ceiling entirely.
        //
        // **The fixture has to be the awkward shape or it proves nothing.** The 64px probe above
        // cannot reproduce this: it is too small for a re-encode to grow it measurably, and a
        // check written against it passed happily with the bug still in place. This one is the
        // real shape — a big-enough image already written at *low* quality, asked for at high
        // quality, with a target size it is already comfortably under.
        if let lowQualityURL = writeProbeImage(into: temporary,
                                               name: "already-small.jpg",
                                               width: 512, height: 384, quality: 0.3) {
            let source = (try? FileManager.default
                .attributesOfItem(atPath: lowQualityURL.path)[.size] as? NSNumber)??.int64Value ?? 0
            let greedy = ShrinkStage(kind: .image, target: .image(.keep),
                                     quality: 0.9, longestEdge: 0, targetKilobytes: 250)
            if let scrubbed = try? run(lowQualityURL, stage: greedy,
                                       scrub: .nothingButPixels, into: temporary) {
                assert(scrubbed.size <= source,
                       "scrubbing waived the size ceiling and grew the file: \(source) → \(scrubbed.size)")
            }
            // And the scrub still has to have happened — the ceiling must not be bought by
            // quietly handing the original bytes back with its metadata intact.
            if let scrubbed = try? run(lowQualityURL, stage: greedy,
                                       scrub: .nothingButPixels, into: temporary) {
                let left = MetadataPass.inspect(scrubbed.outputURL, kind: .image)
                assert(!left.contains { $0.category == .location },
                       "the size ceiling was honoured by skipping the scrub — GPS survived")
            }
        }

        // The ceiling itself: the smaller of the target and the original wins, and only a format
        // change lifts it.
        assert(encodeCeiling(targetKilobytes: 250, originalSize: 166_200, formatChanged: false) == 166_200,
               "a file already under target must still not be allowed to grow")
        assert(encodeCeiling(targetKilobytes: 250, originalSize: 900_000, formatChanged: false) == 250_000,
               "the target is the ceiling when it is the smaller of the two")
        assert(encodeCeiling(targetKilobytes: 250, originalSize: 100, formatChanged: true) == 250_000,
               "changing the format lifts the original-size ceiling — the growth is the point")
        assert(encodeCeiling(targetKilobytes: 0, originalSize: 166_200, formatChanged: false) == 166_200,
               "with no target set the original size is still a ceiling")

        // Two runs of the same file do not overwrite each other.
        let second = try? run(sourceURL, stage: stage, scrub: .shareSafe, into: temporary)
        assert(second?.outputURL != outcome.outputURL, "a second result must not overwrite the first")

        // A .jpg stays a .jpg. `preferredFilenameExtension` answers "jpeg", which would rename
        // every photo in a folder for no reason the user asked for.
        assert(outcome.outputURL.pathExtension == "jpg",
               "an unchanged format must keep the source's own extension, got .\(outcome.outputURL.pathExtension)")
        let converted = try? uniqueDestination(for: sourceURL, type: .png, in: temporary)
        assert(converted?.pathExtension == "png", "a real conversion must take the new extension")

        // A target size is actually reached rather than quietly ignored.
        var targeted = ShrinkStage(kind: .image, target: .image(.jpeg), quality: 0.95, longestEdge: 0)
        targeted.targetKilobytes = 4
        if let small = try? run(sourceURL, stage: targeted, scrub: .shareSafe, into: temporary) {
            assert(small.quality < 0.95, "a target size must actually push the quality down")
        }
    }

    private static func solid(width: Int, height: Int, gray: Double) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private static func noise(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        // Deterministic, so the check does not flicker between runs.
        var seed: UInt64 = 0x9e3779b97f4a7c15
        for y in 0..<height {
            for x in 0..<width {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let value = Double((seed >> 33) & 0xff) / 255.0
                context.setFillColor(gray: value, alpha: 1)
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return context.makeImage()!
    }

    /// A small JPEG carrying GPS and an embedded thumbnail, so the scrub check has something real
    /// to strip.
    /// A JPEG carrying GPS and a camera serial, for the checks to strip.
    ///
    /// `quality` matters: a probe written at the *default* quality cannot be grown by a re-encode,
    /// so a size-ceiling check built on one passes whether or not the ceiling works. Pass a low
    /// quality to get a fixture a greedy re-encode will genuinely inflate.
    private static func writeProbeImage(into folder: URL,
                                        name: String = "probe.jpg",
                                        width: Int = 200,
                                        height: Int = 120,
                                        quality: Double? = nil) -> URL? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        var properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 51.5074,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 0.1278,
                kCGImagePropertyGPSLongitudeRef: "W",
            ] as [CFString: Any],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifBodySerialNumber: "SN12345",
            ] as [CFString: Any],
        ]
        if let quality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, noise(width: width, height: height), properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return url
    }
}
