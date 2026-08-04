import Foundation
import UniformTypeIdentifiers

/// What a dropped file is, as far as the planner cares. Kinds pick the lane; the badge shown on
/// the row is finer-grained than the kind (`HEIC`, not `IMAGE`) because that is what the user
/// recognises.
enum Kind: String, CaseIterable, Codable {
    case image, document, archive, audio, video, other

    var lane: String {
        switch self {
        case .image:    return "Photos"
        case .document: return "Documents"
        case .archive:  return "Archives"
        case .audio:    return "Audio"
        case .video:    return "Video"
        case .other:    return "Other files"
        }
    }

    /// Plural noun for counts: "22 photos, 1 video, 3 docs".
    func counted(_ n: Int) -> String {
        let noun: (String, String)
        switch self {
        case .image:    noun = ("photo", "photos")
        case .document: noun = ("doc", "docs")
        case .archive:  noun = ("archive", "archives")
        case .audio:    noun = ("audio file", "audio files")
        case .video:    noun = ("video", "videos")
        case .other:    noun = ("file", "files")
        }
        return "\(n) \(n == 1 ? noun.0 : noun.1)"
    }

    /// Can trinket make this smaller or change its format at all? `other` cannot — it passes
    /// through, and the row says so rather than showing a progress bar that never moves.
    var isConvertible: Bool { self != .other }
}

/// Identifies a file by UTType, falling back to its extension when the type system has no opinion
/// (a file with no extension and no xattr, or a type this OS has never heard of).
enum Identify {
    /// Extensions the archive engine can actually open, via libarchive. RAR is deliberately
    /// absent — the unrar licence does not permit redistribution, so claiming it would be a lie.
    static let archiveExtensions: Set<String> = [
        "zip", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "7z", "cpio", "iso", "cab", "ar"
    ]

    static func kind(of url: URL) -> Kind {
        if let type = UTType(filenameExtension: url.pathExtension.lowercased()) {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
            if type.conforms(to: .audio) { return .audio }
            if type.conforms(to: .archive) || archiveExtensions.contains(url.pathExtension.lowercased()) {
                return .archive
            }
            if type.conforms(to: .pdf) || type.conforms(to: .text)
                || type.conforms(to: .rtf) || type.conforms(to: .presentation)
                || type.conforms(to: .spreadsheet) || type.conforms(to: .content) {
                return .document
            }
        }
        if archiveExtensions.contains(url.pathExtension.lowercased()) { return .archive }
        return .other
    }

    /// The row badge. Hugs its text — no fixed frame — and is charcoal on a chip, never accent.
    static func badge(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "JPEG"
        case "tif", "tiff": return "TIFF"
        case "heic", "heif": return "HEIC"
        case "png", "gif", "webp", "bmp", "svg", "avif", "pdf", "zip", "epub", "docx", "rtf":
            return ext.uppercased()
        default: break
        }
        switch kind(of: url) {
        case .image:    return ext.isEmpty ? "IMAGE" : ext.uppercased()
        case .document: return ext.isEmpty ? "DOC" : ext.uppercased()
        case .archive:  return ext.isEmpty ? "ARCHIVE" : ext.uppercased()
        case .audio:    return "AUDIO"
        case .video:    return "VIDEO"
        case .other:    return ext.isEmpty ? "FILE" : ext.uppercased()
        }
    }

    static func selfCheck() {
        assert(kind(of: URL(filePath: "/x/a.heic")) == .image)
        assert(kind(of: URL(filePath: "/x/a.JPG")) == .image, "case must not matter")
        assert(kind(of: URL(filePath: "/x/a.mp4")) == .video)
        assert(kind(of: URL(filePath: "/x/a.mp3")) == .audio)
        assert(kind(of: URL(filePath: "/x/a.pdf")) == .document)
        assert(kind(of: URL(filePath: "/x/a.zip")) == .archive)
        assert(kind(of: URL(filePath: "/x/a.7z")) == .archive, "7z has no UTType on every OS")
        assert(kind(of: URL(filePath: "/x/a.tar.gz")) == .archive)
        assert(kind(of: URL(filePath: "/x/binary")) == .other)

        assert(badge(for: URL(filePath: "/x/a.jpeg")) == "JPEG")
        assert(badge(for: URL(filePath: "/x/a.jpg")) == "JPEG", "jpg and jpeg read the same")
        assert(badge(for: URL(filePath: "/x/clip.mp4")) == "VIDEO")
        assert(badge(for: URL(filePath: "/x/a.heic")) == "HEIC")
        // The badge hugs its text, so a long extension must not be silently truncated here.
        assert(badge(for: URL(filePath: "/x/a.sketch")) == "SKETCH")

        assert(Kind.image.counted(1) == "1 photo")
        assert(Kind.image.counted(22) == "22 photos")
        assert(!Kind.other.isConvertible)
    }
}
