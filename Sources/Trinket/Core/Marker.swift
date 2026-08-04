import Foundation

/// Marks the files trinket writes, so it never re-processes its own output.
///
/// With results going **beside the original** — the shipped default — every run leaves its output
/// in the same folder as its input. Drop that folder again and the previous run's results are
/// inputs: they get re-encoded to `photo 1-2.jpg`, then `photo 1-3.jpg`, and the batch fills with
/// copies of copies. It also wrecks the headline, because a folder of already-shrunk files reports
/// a tiny saving that has nothing to do with the work just done.
///
/// An extended attribute is the right place for this. It is invisible in Finder, travels with the
/// file on APFS, costs nothing to read, and — unlike a naming convention — cannot be defeated by
/// the user renaming the file, which they are explicitly encouraged to do.
enum Marker {
    private static let name = "com.trinket.produced"

    /// Stamps a file trinket just wrote.
    static func stamp(_ url: URL) {
        let value = Array("1".utf8)
        _ = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return setxattr(path, name, value, value.count, 0, 0)
        }
    }

    /// True when trinket produced this file itself.
    static func isProduced(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return getxattr(path, name, nil, 0, 0, 0) > 0
        }
    }

    static func selfCheck() {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "trinket-marker-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let file = folder.appending(path: "a.jpg")
        try? Data("x".utf8).write(to: file)

        assert(!isProduced(file), "a file nobody stamped must not read as produced")
        stamp(file)
        assert(isProduced(file), "the stamp did not stick")

        // It must survive a rename — renaming results is a feature, so a naming convention would
        // have been useless here.
        let renamed = folder.appending(path: "holiday-001.jpg")
        try? FileManager.default.moveItem(at: file, to: renamed)
        assert(isProduced(renamed), "the stamp must survive a rename")

        // And a copy made by the user is still trinket's output.
        let copied = folder.appending(path: "copy.jpg")
        try? FileManager.default.copyItem(at: renamed, to: copied)
        assert(isProduced(copied), "the stamp must survive a copy")

        // A file that does not exist answers false rather than crashing.
        assert(!isProduced(folder.appending(path: "nothing.jpg")))
    }
}
