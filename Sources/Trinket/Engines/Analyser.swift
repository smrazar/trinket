import Foundation
import ImageIO

/// Turns dropped URLs into items, facts and a metadata report — the "analysing" screen. Runs off
/// the main thread; the only thing that touches the UI is the handful of published properties the
/// caller writes back.
enum Analyser {

    struct Result {
        var items: [ItemSeed] = []
        var facts: [FileFact] = []
        var report = ScrubReport()
        /// Every archive that was opened, in drop order.
        var droppedContainers: [URL] = []
        var archiveEntryCount = 0
        /// The unpacked folders. The caller owns them and must remove them.
        var unpackedRoots: [URL] = []
        /// Files left out because trinket produced them itself on an earlier run.
        var alreadyProduced = 0

        /// The single container, when exactly one was dropped — what the list header names.
        var droppedContainer: URL? {
            droppedContainers.count == 1 ? droppedContainers[0] : nil
        }
    }

    /// A plain value describing one file — `Item` is main-actor bound, so the background pass
    /// produces these and the main actor turns them into items.
    struct ItemSeed {
        let url: URL
        let container: URL?
        let findings: [MetadataFinding]
        let fact: FileFact
    }

    /// Extensions whose bytes are already compressed, so a zip cannot squeeze them further.
    private static let compressedExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "gif", "webp", "avif", "mp4", "mov", "m4v",
        "mp3", "m4a", "aac", "opus", "ogg", "flac", "pdf", "zip", "7z", "gz", "xz", "bz2",
    ]

    /// The expensive half. Never call this on the main thread.
    static func analyse(_ urls: [URL], unpackArchives: Bool) -> Result {
        var result = Result()

        // **Every** dropped archive is opened, not just a lone one. Requiring it to be the only
        // thing dropped meant a zip alongside a few photos silently passed through at full size —
        // which is the exact case the app exists for. Each entry remembers its container, so a
        // mixed drop still knows which file came from where.
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }

            if isDirectory.boolValue {
                // A dropped folder becomes its contents. Nobody drags a folder onto a compressor
                // expecting the folder itself to be the unit of work — and an archive sitting in
                // that folder gets opened exactly as if it had been dropped on its own. A folder
                // is not a layer of compression, so "one layer, not two" never applied to it;
                // treating it as one meant dropping a folder silently skipped every zip in it.
                for file in ArchivePass.walk(url) {
                    absorb(file, into: &result, unpackArchives: unpackArchives)
                }
                continue
            }

            absorb(url, into: &result, unpackArchives: unpackArchives)
        }

        result.facts = result.items.map(\.fact)
        result.report = MetadataPass.merge(result.items.map(\.findings))

        let counts = Dictionary(grouping: result.items, by: { $0.fact.kind })
            .map { "\($0.value.count) \($0.key.rawValue)" }
            .sorted()
        logInfo("classify: \(counts.joined(separator: ", "))")
        if result.alreadyProduced > 0 {
            logInfo("skipped \(result.alreadyProduced) "
                    + "\(result.alreadyProduced == 1 ? "file" : "files") trinket already produced")
        }
        if result.report.filesScanned > 0, !result.report.isEmpty {
            let carrying = result.report.findings.map(\.fileCount).max() ?? 0
            logInfo("scan metadata… \(carrying) items with GPS/EXIF")
        }
        return result
    }

    /// Takes one real file and adds it to the result — opening it first if it is an archive.
    ///
    /// Both entry points route through here, which is the point: a zip is opened whether it was
    /// dropped directly or found inside a dropped folder. An archive *inside an archive* is still
    /// left alone, because `unpack` is never called on an entry.
    private static func absorb(_ url: URL, into result: inout Result, unpackArchives: Bool) {
        // Results go beside the original by default, so a folder dropped twice would otherwise
        // hand trinket its own output as input — copies of copies, and a headline that measures
        // nothing. Entries unpacked from an archive are exempt: they live in a scratch folder and
        // carry the stamp only because the archive they came from was produced here.
        guard !Marker.isProduced(url) else {
            result.alreadyProduced += 1
            return
        }

        guard unpackArchives, Identify.kind(of: url) == .archive else {
            result.items.append(seed(for: url, container: nil))
            return
        }
        guard let contents = try? ArchivePass.unpack(url) else {
            logWarn("could not open \(url.lastPathComponent) — leaving it packed")
            result.items.append(seed(for: url, container: nil))
            return
        }
        result.droppedContainers.append(url)
        result.unpackedRoots.append(contents.root)
        result.archiveEntryCount += contents.files.count
        logInfo("open \(url.lastPathComponent) → \(contents.files.count) entries")
        for file in contents.files {
            result.items.append(seed(for: file, container: url))
        }
    }

    private static func seed(for url: URL, container: URL?) -> ItemSeed {
        let kind = Identify.kind(of: url)
        let size = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.int64Value ?? 0

        var fact = FileFact(kind: kind, size: size)
        fact.isAlreadyCompressed = compressedExtensions.contains(url.pathExtension.lowercased())
        if kind == .image { fact.longestEdge = longestEdge(of: url) }

        let findings = MetadataPass.inspect(url, kind: kind)
        return ItemSeed(url: url, container: container, findings: findings, fact: fact)
    }

    /// Reads the pixel dimensions from the header alone — no decode. A 48-megapixel HEIC answers
    /// this in microseconds, which matters when a drop is 400 photos.
    static func longestEdge(of url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return 0 }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        return max(width, height)
    }

    static func selfCheck() {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "trinket-analyse-\(UUID().uuidString)", directoryHint: .isDirectory)
        let nested = folder.appending(path: "sub", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try? Data(repeating: 1, count: 1000).write(to: folder.appending(path: "a.txt"))
        try? Data(repeating: 2, count: 2000).write(to: nested.appending(path: "b.bin"))

        // A dropped folder becomes its contents, recursively.
        let expanded = analyse([folder], unpackArchives: false)
        assert(expanded.items.count == 2, "a dropped folder must expand to the files inside it")
        assert(expanded.facts.reduce(0) { $0 + $1.size } == 3000)

        // Sizes and the already-compressed flag land on the facts the planner reads.
        let jpeg = folder.appending(path: "photo.jpg")
        try? Data(repeating: 3, count: 500).write(to: jpeg)
        let flags = analyse([jpeg], unpackArchives: false)
        assert(flags.facts.first?.isAlreadyCompressed == true,
               "a JPEG must be marked incompressible or the bundle will try to squeeze it")
        assert(analyse([folder.appending(path: "a.txt")], unpackArchives: false)
            .facts.first?.isAlreadyCompressed == false)

        // A single dropped archive is opened and its entries become the items.
        let staging = folder.appending(path: "staging", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try? Data(repeating: 4, count: 800).write(to: staging.appending(path: "inside.txt"))
        if let archive = try? ArchivePass.bundle(staging, named: "probe", level: 6, into: folder) {
            let opened = analyse([archive], unpackArchives: true)
            assert(opened.droppedContainer == archive)
            assert(opened.archiveEntryCount == 1)
            assert(opened.items.count == 1 && opened.items[0].url.lastPathComponent == "inside.txt")
            assert(opened.items[0].container == archive, "an entry must remember which archive it came from")
            for root in opened.unpackedRoots { try? FileManager.default.removeItem(at: root) }

            // …and stays closed when the user asked for the archive itself to be the unit.
            let closed = analyse([archive], unpackArchives: false)
            assert(closed.items.count == 1 && closed.items[0].url == archive)
            assert(closed.droppedContainer == nil)
        }

        // A zip **inside a dropped folder** is opened too. Dropping a folder is how most people
        // hand over a batch, and for a while every archive in one was silently skipped: the
        // folder branch walked its contents straight into plain items without ever calling
        // unpack. The "one layer, not two" rule is about archives inside *archives*; a folder is
        // not a layer of compression.
        let dropped = folder.appending(path: "dropped", directoryHint: .isDirectory)
        let inner = folder.appending(path: "inner", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dropped, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try? Data(repeating: 5, count: 700).write(to: inner.appending(path: "packed.txt"))
        try? Data(repeating: 6, count: 300).write(to: dropped.appending(path: "loose.txt"))
        if let nested = try? ArchivePass.bundle(inner, named: "inside", level: 6, into: dropped) {
            let walked = analyse([dropped], unpackArchives: true)
            defer { for root in walked.unpackedRoots { try? FileManager.default.removeItem(at: root) } }
            // Compared by name: the directory enumerator resolves `/var` to `/private/var`, so
            // the two URLs differ by a symlink while naming the same file.
            assert(walked.droppedContainers.map(\.lastPathComponent) == [nested.lastPathComponent],
                   "an archive inside a dropped folder must be opened, not skipped")
            assert(walked.items.contains { $0.url.lastPathComponent == "packed.txt" },
                   "the archive's contents must reach the batch")
            assert(walked.items.contains { $0.url.lastPathComponent == "loose.txt" })
            assert(!walked.items.contains { $0.fact.kind == .archive },
                   "the archive itself must not also appear as an item")
        }

        // Files trinket produced itself are left out of a later drop. Without this, results
        // going beside the original mean the next drop of that folder re-encodes the last run's
        // output — copies of copies, and a headline measuring the wrong thing.
        let produced = folder.appending(path: "produced.txt")
        try? Data(repeating: 9, count: 400).write(to: produced)
        Marker.stamp(produced)
        let mixed = analyse([produced, folder.appending(path: "a.txt")], unpackArchives: false)
        assert(mixed.alreadyProduced == 1, "a stamped file must be left out")
        assert(mixed.items.count == 1 && mixed.items[0].url.lastPathComponent == "a.txt",
               "only the file trinket did not produce should reach the batch")

        // A file that no longer exists is skipped rather than crashing the analysis.
        let ghost = folder.appending(path: "gone.txt")
        assert(analyse([ghost], unpackArchives: false).items.isEmpty)
    }
}
