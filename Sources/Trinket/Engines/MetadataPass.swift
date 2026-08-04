import Foundation
import ImageIO
import AVFoundation
import PDFKit

/// Finds what a file is carrying, and decides what survives a scrub. The finding half runs before
/// the user presses Run, so removal is verifiable rather than promised.
///
/// Metadata hides in places a "strip EXIF" pass never looks: an embedded thumbnail of the
/// *uncropped* original, a PDF's revision history, GPS on an iPhone video's track. Each of those
/// is checked here by name.
enum MetadataPass {

    // MARK: - Finding

    static func inspect(_ url: URL, kind: Kind) -> [MetadataFinding] {
        switch kind {
        case .image:    return inspectImage(url)
        case .document: return inspectDocument(url)
        case .video, .audio: return inspectMedia(url)
        case .archive, .other: return []
        }
    }

    private static func inspectImage(_ url: URL) -> [MetadataFinding] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return [] }

        var findings: [MetadataFinding] = []
        func note(_ category: MetadataCategory, _ sample: String? = nil) {
            findings.append(MetadataFinding(category: category, fileCount: 1, sample: sample))
        }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]

        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            note(.location, coordinate(from: gps))
        }
        if let serial = exif[kCGImagePropertyExifBodySerialNumber] as? String, !serial.isEmpty {
            note(.cameraSerial, serial)
        } else if let make = tiff[kCGImagePropertyTIFFMake] as? String,
                  let model = tiff[kCGImagePropertyTIFFModel] as? String {
            note(.cameraSerial, "\(make) \(model)")
        }
        if properties[kCGImagePropertyMakerAppleDictionary] != nil
            || iptc[kCGImagePropertyIPTCEditStatus] != nil {
            note(.editHistory)
        }
        // The one that matters most. A JPEG's IFD1 carries a small copy of the frame *before* the
        // crop, so cropping someone out and sharing the file leaks them anyway.
        if hasEmbeddedThumbnail(url) {
            note(.embeddedThumbnail)
        }
        if let artist = tiff[kCGImagePropertyTIFFArtist] as? String, !artist.isEmpty {
            note(.author, artist)
        } else if let byline = iptc[kCGImagePropertyIPTCByline] as? String, !byline.isEmpty {
            note(.author, byline)
        } else if let copyright = tiff[kCGImagePropertyTIFFCopyright] as? String, !copyright.isEmpty {
            note(.author, copyright)
        }
        if let date = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            note(.timestamps, date)
        }
        if let software = tiff[kCGImagePropertyTIFFSoftware] as? String, !software.isEmpty {
            note(.software, software)
        }
        if let profile = properties[kCGImagePropertyProfileName] as? String {
            note(.colourProfile, profile)
        }
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation != 1 {
            note(.orientation, "rotated")
        }
        return findings
    }

    /// True when the file really carries a stored thumbnail — a second, smaller picture of what
    /// the frame looked like *before* the crop.
    ///
    /// ImageIO cannot answer this. `CGImageSourceCreateThumbnailAtIndex` with both
    /// `…FromImageAlways` and `…FromImageIfAbsent` set to false still renders one from the full
    /// image and returns it, so the obvious check reports "yes" for every file ever written,
    /// including a JPEG this app produced two lines earlier. Measured, not assumed.
    ///
    /// So read the bytes: find the APP1/Exif segment, walk IFD0 to the pointer that follows it,
    /// and look in IFD1 for tag 0x0201 (JPEGInterchangeFormat) — the offset of the stored
    /// thumbnail. No tag, no thumbnail.
    static func hasEmbeddedThumbnail(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        // EXIF lives at the front; an APP1 segment is capped at 64 KB and a few may precede it.
        guard let head = try? handle.read(upToCount: 512 * 1024), head.count > 4 else { return false }
        let bytes = [UInt8](head)
        guard bytes[0] == 0xFF, bytes[1] == 0xD8 else { return false }  // JPEG SOI

        var index = 2
        while index + 4 < bytes.count {
            guard bytes[index] == 0xFF else { index += 1; continue }
            let marker = bytes[index + 1]
            // Padding and standalone markers carry no length field.
            if marker == 0xFF || marker == 0x01 || (0xD0...0xD8).contains(marker) {
                index += 2
                continue
            }
            // Start of scan or end of image: the metadata is behind us.
            if marker == 0xDA || marker == 0xD9 { return false }

            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            guard length >= 2 else { return false }

            if marker == 0xE1, index + 10 <= bytes.count,
               bytes[index + 4] == 0x45, bytes[index + 5] == 0x78,   // "Ex"
               bytes[index + 6] == 0x69, bytes[index + 7] == 0x66 {  // "if"
                // The TIFF header starts after "Exif\0\0".
                if scanForThumbnailTag(bytes, tiffStart: index + 10) { return true }
            }
            index += 2 + length
        }
        return false
    }

    private static func scanForThumbnailTag(_ bytes: [UInt8], tiffStart: Int) -> Bool {
        guard tiffStart + 8 <= bytes.count else { return false }
        let isLittleEndian = bytes[tiffStart] == 0x49   // 'I' for Intel

        func u16(_ offset: Int) -> Int {
            guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
            return isLittleEndian
                ? Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
                : Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
        }
        func u32(_ offset: Int) -> Int {
            guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
            return isLittleEndian
                ? Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
                : Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        }

        guard u16(tiffStart + 2) == 42 else { return false }   // the TIFF magic number
        let ifd0 = tiffStart + u32(tiffStart + 4)
        guard ifd0 + 2 <= bytes.count else { return false }

        let entryCount = u16(ifd0)
        guard entryCount < 4096 else { return false }          // refuse a corrupt count
        // The 4-byte pointer to the next IFD sits after IFD0's fixed-width entries.
        let nextPointer = u32(ifd0 + 2 + entryCount * 12)
        guard nextPointer != 0 else { return false }            // no IFD1 at all

        let ifd1 = tiffStart + nextPointer
        guard ifd1 + 2 <= bytes.count else { return false }
        let thumbnailEntries = u16(ifd1)
        guard thumbnailEntries > 0, thumbnailEntries < 4096 else { return false }

        for entry in 0..<thumbnailEntries where u16(ifd1 + 2 + entry * 12) == 0x0201 {
            return true
        }
        return false
    }

    private static func inspectDocument(_ url: URL) -> [MetadataFinding] {
        guard url.pathExtension.lowercased() == "pdf",
              let document = PDFDocument(url: url) else { return [] }
        var findings: [MetadataFinding] = []
        let attributes = document.documentAttributes ?? [:]

        if let author = attributes[PDFDocumentAttribute.authorAttribute] as? String, !author.isEmpty {
            findings.append(.init(category: .author, fileCount: 1, sample: author))
        }
        if let creator = attributes[PDFDocumentAttribute.creatorAttribute] as? String, !creator.isEmpty {
            findings.append(.init(category: .software, fileCount: 1, sample: creator))
        } else if let producer = attributes[PDFDocumentAttribute.producerAttribute] as? String, !producer.isEmpty {
            findings.append(.init(category: .software, fileCount: 1, sample: producer))
        }
        if attributes[PDFDocumentAttribute.creationDateAttribute] != nil
            || attributes[PDFDocumentAttribute.modificationDateAttribute] != nil {
            findings.append(.init(category: .timestamps, fileCount: 1, sample: nil))
        }
        // A PDF keeps its own past: incremental saves leave earlier revisions in the file, so
        // text "deleted" in the last edit is still in there. More than one %%EOF marks it.
        if revisionCount(of: url) > 1 {
            findings.append(.init(category: .editHistory, fileCount: 1,
                                  sample: "\(revisionCount(of: url)) saved revisions"))
        }
        return findings
    }

    /// Counts `%%EOF` markers. Reads the file in a stream — a PDF can be hundreds of megabytes and
    /// this runs across a whole drop.
    private static func revisionCount(of url: URL) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        let marker = Data("%%EOF".utf8)
        var count = 0
        var carry = Data()
        while let chunk = try? handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            var window = carry + chunk
            var searchRange = window.startIndex..<window.endIndex
            while let found = window.range(of: marker, in: searchRange) {
                count += 1
                searchRange = found.upperBound..<window.endIndex
            }
            // Keep the last few bytes in case a marker straddles the chunk boundary.
            carry = window.count > marker.count ? window.suffix(marker.count - 1) : window
            window = Data()
        }
        return count
    }

    private static func inspectMedia(_ url: URL) -> [MetadataFinding] {
        let asset = AVURLAsset(url: url)
        // Analysis runs off the main thread, so blocking here is correct; the async `load(.metadata)`
        // would only push the same wait through a continuation.
        let metadata = (try? loadSynchronously { try await asset.load(.metadata) }) ?? []
        let quickTime = (try? loadSynchronously {
            try await asset.loadMetadata(for: .quickTimeMetadata)
        }) ?? []

        var findings: [MetadataFinding] = []
        for item in metadata + quickTime {
            let sample = (try? loadSynchronously { try await item.load(.stringValue) }) ?? nil
            // An iPhone video hides its GPS in a QuickTime user-data atom rather than in common
            // metadata, so a pass that reads only `commonKey` calls a located file clean.
            if (item.key as? String) == "com.apple.quicktime.location.ISO6709" {
                findings.append(.init(category: .location, fileCount: 1, sample: sample))
                continue
            }
            guard let key = item.commonKey else { continue }
            switch key {
            case .commonKeyLocation:
                findings.append(.init(category: .location, fileCount: 1, sample: sample))
            case .commonKeyCreationDate:
                findings.append(.init(category: .timestamps, fileCount: 1, sample: sample))
            case .commonKeyMake, .commonKeyModel:
                findings.append(.init(category: .cameraSerial, fileCount: 1, sample: sample))
            case .commonKeySoftware:
                findings.append(.init(category: .software, fileCount: 1, sample: sample))
            case .commonKeyAuthor, .commonKeyArtist, .commonKeyCopyrights:
                findings.append(.init(category: .author, fileCount: 1, sample: sample))
            default:
                break
            }
        }
        return findings
    }

    /// Bridges one `async` AVFoundation load into the synchronous analysis pass. Never call this
    /// from the main thread — it parks the caller until the load lands.
    private static func loadSynchronously<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached {
            do { box.value = .success(try await work()) }
            catch { box.value = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        switch box.value {
        case .success(let value): return value
        case .failure(let error): throw error
        case nil: throw CocoaError(.fileReadUnknown)
        }
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: Result<T, Error>?
    }

    /// Rolls per-file findings up into the batch report the sidebar and inspector show.
    static func merge(_ perFile: [[MetadataFinding]]) -> ScrubReport {
        var counts: [MetadataCategory: Int] = [:]
        var samples: [MetadataCategory: String] = [:]
        for file in perFile {
            // A file that lists a category twice still counts once.
            for category in Set(file.map(\.category)) {
                counts[category, default: 0] += 1
                if samples[category] == nil,
                   let sample = file.first(where: { $0.category == category })?.sample {
                    samples[category] = sample
                }
            }
        }
        let findings = counts.map { MetadataFinding(category: $0.key, fileCount: $0.value, sample: samples[$0.key]) }
        return ScrubReport(findings: findings, filesScanned: perFile.count)
    }

    // MARK: - Removing

    /// The properties dictionary to hand `CGImageDestination`, given the level in force.
    ///
    /// This builds a *fresh* dictionary of what survives rather than deleting keys from the
    /// source. Deleting means every metadata block nobody thought of — maker notes, XMP packets,
    /// a vendor's private IFD — rides along untouched. Building means only named things survive.
    static func imageProperties(keeping level: ScrubLevel,
                                from source: [CFString: Any],
                                quality: Double,
                                isLossy: Bool) -> [CFString: Any] {
        var output: [CFString: Any] = [:]
        if isLossy { output[kCGImageDestinationLossyCompressionQuality] = quality }

        // Orientation is baked into the pixels by the image pass, so the file must declare
        // "already upright" or a viewer will rotate it a second time.
        output[kCGImagePropertyOrientation] = 1

        guard level != .keepEverything else {
            var everything = source
            everything[kCGImagePropertyOrientation] = 1
            if isLossy { everything[kCGImageDestinationLossyCompressionQuality] = quality }
            return everything
        }

        var exif: [CFString: Any] = [:]
        var tiff: [CFString: Any] = [:]
        var iptc: [CFString: Any] = [:]

        let sourceExif = source[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let sourceTiff = source[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let sourceIptc = source[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]

        if !level.removes(.timestamps) {
            exif[kCGImagePropertyExifDateTimeOriginal] = sourceExif[kCGImagePropertyExifDateTimeOriginal]
            exif[kCGImagePropertyExifDateTimeDigitized] = sourceExif[kCGImagePropertyExifDateTimeDigitized]
            tiff[kCGImagePropertyTIFFDateTime] = sourceTiff[kCGImagePropertyTIFFDateTime]
        }
        if !level.removes(.author) {
            tiff[kCGImagePropertyTIFFArtist] = sourceTiff[kCGImagePropertyTIFFArtist]
            tiff[kCGImagePropertyTIFFCopyright] = sourceTiff[kCGImagePropertyTIFFCopyright]
            iptc[kCGImagePropertyIPTCByline] = sourceIptc[kCGImagePropertyIPTCByline]
            iptc[kCGImagePropertyIPTCCopyrightNotice] = sourceIptc[kCGImagePropertyIPTCCopyrightNotice]
        }
        if !level.removes(.cameraSerial) {
            tiff[kCGImagePropertyTIFFMake] = sourceTiff[kCGImagePropertyTIFFMake]
            tiff[kCGImagePropertyTIFFModel] = sourceTiff[kCGImagePropertyTIFFModel]
            exif[kCGImagePropertyExifBodySerialNumber] = sourceExif[kCGImagePropertyExifBodySerialNumber]
        }
        if !level.removes(.software) {
            tiff[kCGImagePropertyTIFFSoftware] = sourceTiff[kCGImagePropertyTIFFSoftware]
        }
        if !level.removes(.location) {
            output[kCGImagePropertyGPSDictionary] = source[kCGImagePropertyGPSDictionary]
        }

        // Compact: an empty sub-dictionary still writes an empty EXIF block.
        exif = exif.compactMapValues { $0 }
        tiff = tiff.compactMapValues { $0 }
        iptc = iptc.compactMapValues { $0 }
        if !exif.isEmpty { output[kCGImagePropertyExifDictionary] = exif }
        if !tiff.isEmpty { output[kCGImagePropertyTIFFDictionary] = tiff }
        if !iptc.isEmpty { output[kCGImagePropertyIPTCDictionary] = iptc }

        return output
    }

    // MARK: - Self-check

    static func selfCheck() {
        // The build-don't-delete rule. A source carrying a maker note and a GPS block must come
        // out the far side with neither, at share-safe — including the keys nobody enumerated.
        let source: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: ["lat": 51.5] as [CFString: Any],
            kCGImagePropertyMakerAppleDictionary: ["secret": "value"] as [CFString: Any],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifBodySerialNumber: "SN12345",
                kCGImagePropertyExifDateTimeOriginal: "2026:08:03 12:00:00",
            ] as [CFString: Any],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFArtist: "M",
                kCGImagePropertyTIFFSoftware: "Photos 9.0",
            ] as [CFString: Any],
        ]

        let safe = imageProperties(keeping: .shareSafe, from: source, quality: 0.75, isLossy: true)
        assert(safe[kCGImagePropertyGPSDictionary] == nil, "share-safe must drop GPS")
        assert(safe[kCGImagePropertyMakerAppleDictionary] == nil,
               "an unenumerated maker note must not ride along — build the dictionary, never filter it")
        let safeExif = safe[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        assert(safeExif[kCGImagePropertyExifBodySerialNumber] == nil, "share-safe must drop the serial")
        assert(safeExif[kCGImagePropertyExifDateTimeOriginal] != nil, "share-safe keeps the date")
        let safeTiff = safe[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        assert(safeTiff[kCGImagePropertyTIFFArtist] != nil, "share-safe keeps the byline")
        assert(safeTiff[kCGImagePropertyTIFFSoftware] == nil, "share-safe drops the app that touched it")

        // Orientation is baked into the pixels, so every level declares upright — otherwise a
        // viewer rotates an already-rotated picture.
        for level in ScrubLevel.allCases {
            let output = imageProperties(keeping: level, from: source, quality: 0.75, isLossy: true)
            assert(output[kCGImagePropertyOrientation] as? Int == 1,
                   "\(level) must declare orientation 1 — the rotation is already in the pixels")
        }

        // Location-only is surgical: GPS goes, everything else stays.
        let located = imageProperties(keeping: .locationOnly, from: source, quality: 0.75, isLossy: true)
        assert(located[kCGImagePropertyGPSDictionary] == nil)
        let locatedExif = located[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        assert(locatedExif[kCGImagePropertyExifBodySerialNumber] != nil,
               "location-only must not take the serial too")

        // Nothing-but-pixels leaves nothing but the quality hint and the orientation flag.
        let bare = imageProperties(keeping: .nothingButPixels, from: source, quality: 0.75, isLossy: true)
        assert(bare[kCGImagePropertyExifDictionary] == nil && bare[kCGImagePropertyTIFFDictionary] == nil)
        assert(bare[kCGImagePropertyGPSDictionary] == nil)

        // Keep-everything really does keep the maker note.
        let all = imageProperties(keeping: .keepEverything, from: source, quality: 0.75, isLossy: true)
        assert(all[kCGImagePropertyMakerAppleDictionary] != nil)

        // Quality is only written for a lossy destination; PNG has no such knob.
        assert(imageProperties(keeping: .shareSafe, from: [:], quality: 0.75,
                               isLossy: false)[kCGImageDestinationLossyCompressionQuality] == nil)

        // Rolling up: two files with GPS and one without gives a count of two, not three.
        let report = merge([
            [.init(category: .location, fileCount: 1, sample: "51.5, -0.1"),
             .init(category: .cameraSerial, fileCount: 1, sample: nil)],
            [.init(category: .location, fileCount: 1, sample: nil)],
            [.init(category: .colourProfile, fileCount: 1, sample: "sRGB")],
        ])
        assert(report.filesScanned == 3)
        assert(report.findings.first { $0.category == .location }?.fileCount == 2)
        assert(report.findings.first { $0.category == .location }?.sample == "51.5, -0.1",
               "the first real sample wins, so the inspector can show an actual value")
        assert(report.findings.first { $0.category == .cameraSerial }?.fileCount == 1)

        thumbnailDetectorCheck()
    }

    /// The detector that cost an afternoon. ImageIO answers "yes, there's a thumbnail" for a file
    /// it just rendered one from, so this pins the real behaviour: a JPEG written without one must
    /// report false, and the same JPEG written with one must report true. If someone swaps the
    /// byte scan back for `CGImageSourceCreateThumbnailAtIndex`, the first assert fires.
    private static func thumbnailDetectorCheck() {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "trinket-thumbnail-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        func write(_ name: String, embedThumbnail: Bool) -> URL? {
            let url = folder.appending(path: name)
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL, "public.jpeg" as CFString, 1, nil) else { return nil }
            let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8,
                                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.setFillColor(gray: 0.5, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            guard let image = context.makeImage() else { return nil }
            let properties: [CFString: Any] = embedThumbnail
                ? [kCGImageDestinationEmbedThumbnail: true]
                : [:]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            return CGImageDestinationFinalize(destination) ? url : nil
        }

        if let plain = write("plain.jpg", embedThumbnail: false) {
            assert(!hasEmbeddedThumbnail(plain),
                   "a JPEG written without a thumbnail must not report one — ImageIO's own thumbnail API renders one and lies")
        }
        if let embedded = write("embedded.jpg", embedThumbnail: true) {
            assert(hasEmbeddedThumbnail(embedded),
                   "a JPEG written with an embedded thumbnail must be detected")
        }
    }

    private static func coordinate(from gps: [CFString: Any]) -> String? {
        guard let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
              let lon = gps[kCGImagePropertyGPSLongitude] as? Double else { return nil }
        let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
        let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
        return String(format: "%.4f° %@, %.4f° %@", lat, latRef, lon, lonRef)
    }
}
