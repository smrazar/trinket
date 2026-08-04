import Foundation

/// Opening and making archives.
///
/// The most-asked question about this app: *"I zipped my photos and it got bigger."* JPEG, MP4 and
/// PDF have no redundancy left, so 7z at level 9 adds container overhead — 145.3 MB became
/// 146.7 MB, slowly. The answer is a different verb: **shrink what is inside**. Unpack,
/// re-encode the images, repack — the same photos came out at 73.8 MB.
///
/// `/usr/bin/tar` is bsdtar on libarchive, so reading zip / tar / 7z / xz / cpio needs no
/// dependency. RAR is absent on purpose: unrar's licence forbids redistribution, so claiming it
/// would be a lie the first time someone dropped one.
enum ArchivePass {

    struct Contents {
        /// Where the entries were unpacked. The caller owns this and must remove it.
        let root: URL
        let files: [URL]
    }

    enum Failure: LocalizedError {
        case cannotOpen(URL, String)
        case cannotWrite(URL, String)
        case empty(URL)

        var errorDescription: String? {
            switch self {
            case .cannotOpen(let url, let why):
                return why.isEmpty ? "\(url.lastPathComponent) could not be opened." : why
            case .cannotWrite(let url, let why):
                return why.isEmpty ? "Could not write \(url.lastPathComponent)." : why
            case .empty(let url):
                return "\(url.lastPathComponent) is empty."
            }
        }
    }

    private static let tar = URL(filePath: "/usr/bin/tar")
    private static let zip = URL(filePath: "/usr/bin/zip")

    // MARK: - Reading

    /// Lists the entries without extracting, so the plan can say "41 items" before the user runs
    /// anything.
    static func peek(_ url: URL) -> [String] {
        guard let result = try? Shell.run(tar, ["-tf", url.path]), result.ok else { return [] }
        return result.stdout
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.hasSuffix("/") && !$0.isEmpty }
    }

    static func entryCount(_ url: URL) -> Int { peek(url).count }

    /// Unpacks into a fresh temporary folder.
    static func unpack(_ url: URL) throws -> Contents {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "trinket-unpack-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // `-C` keeps extraction inside our folder, and bsdtar refuses absolute paths and `..`
        // components by default — a zip cannot write outside the directory it is unpacked into.
        let result = try Shell.run(tar, ["-xf", url.path, "-C", root.path])
        guard result.ok else {
            try? FileManager.default.removeItem(at: root)
            throw Failure.cannotOpen(url, result.message)
        }

        let files = walk(root)
        guard !files.isEmpty else {
            try? FileManager.default.removeItem(at: root)
            throw Failure.empty(url)
        }
        return Contents(root: root, files: files)
    }

    /// Every real file under a folder, skipping the noise macOS scatters through archives.
    static func walk(_ root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            // `__MACOSX/._name` resource forks are not files the user put there.
            if url.pathComponents.contains("__MACOSX") { continue }
            if url.lastPathComponent.hasPrefix("._") { continue }
            if url.lastPathComponent == ".DS_Store" { continue }
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    // MARK: - Writing

    /// Zips a folder's contents. `level` 1 is the fast path for data that cannot be recompressed:
    /// it produces the same size as level 9 in a fraction of the time.
    ///
    /// `-X` drops the extra file attributes, and `-x` skips the Finder droppings — otherwise the
    /// archive carries `.DS_Store` files that name folders on the sender's machine.
    static func bundle(_ root: URL, named name: String, level: Int, into destination: URL) throws -> URL {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let output = try unusedURL(named: "\(name).zip", in: destination)

        let arguments = [
            "-r", "-q",
            "-\(level.clamped(0, 9))",
            "-X",
            output.path, ".",
            "-x", ".DS_Store", "-x", "__MACOSX/*",
        ]
        // `zip` resolves relative paths against its working directory, which is how the archive
        // ends up with clean entry names rather than the whole temporary path.
        let process = Process()
        process.executableURL = zip
        process.arguments = arguments
        process.currentDirectoryURL = root
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        var errorData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        try process.run()
        process.waitUntilExit()
        group.wait()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.cannotWrite(output, message)
        }
        return output
    }

    static func unusedURL(named name: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appending(path: name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)")
            counter += 1
            if counter > 999 { throw Failure.cannotWrite(candidate, "") }
        }
        return candidate
    }

    // MARK: - Self-check

    static func selfCheck() {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "trinket-archive-\(UUID().uuidString)", directoryHint: .isDirectory)
        let staging = folder.appending(path: "staging", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Something compressible, something nested, and the Finder droppings that must not travel.
        try? String(repeating: "trinket ", count: 4000).data(using: .utf8)?
            .write(to: staging.appending(path: "notes.txt"))
        let nested = staging.appending(path: "inner", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try? Data(repeating: 7, count: 2048).write(to: nested.appending(path: "blob.bin"))
        try? Data("junk".utf8).write(to: staging.appending(path: ".DS_Store"))

        guard let archive = try? bundle(staging, named: "probe", level: 6, into: folder) else {
            assertionFailure("could not write the probe archive")
            return
        }

        let entries = peek(archive)
        assert(entries.contains { $0.hasSuffix("notes.txt") }, "the archive lost a file")
        assert(entries.contains { $0.hasSuffix("blob.bin") }, "the archive lost a nested file")
        assert(!entries.contains { $0.contains(".DS_Store") },
               "a .DS_Store travelled inside the archive — it names folders on the sender's machine")
        assert(entryCount(archive) == 2)

        // Round-trip: what went in comes back out, with the same bytes.
        guard let contents = try? unpack(archive) else {
            assertionFailure("could not unpack the probe archive")
            return
        }
        defer { try? FileManager.default.removeItem(at: contents.root) }
        assert(contents.files.count == 2, "unpack lost a file")
        let restored = contents.files.first { $0.lastPathComponent == "blob.bin" }
        assert(restored != nil)
        assert((try? Data(contentsOf: restored!)) == Data(repeating: 7, count: 2048),
               "a round trip through the archive changed the bytes")

        // Level 1 is the incompressible fast path, and it must still produce a valid archive.
        if let fast = try? bundle(staging, named: "fast", level: 1, into: folder) {
            assert(entryCount(fast) == 2, "the fast path produced a broken archive")
        }

        // A file that is not an archive fails with a reason rather than a crash or a fake success.
        let notAnArchive = folder.appending(path: "plain.txt")
        try? Data("hello".utf8).write(to: notAnArchive)
        assert(peek(notAnArchive).isEmpty)
        do {
            _ = try unpack(notAnArchive)
            assertionFailure("unpacking a text file must throw")
        } catch {
            assert(error is Failure)
        }

        // Two bundles of the same name do not overwrite each other.
        let again = try? bundle(staging, named: "probe", level: 6, into: folder)
        assert(again != nil && again != archive)
    }
}

extension Int {
    func clamped(_ low: Int, _ high: Int) -> Int { Swift.min(Swift.max(self, low), high) }
}
