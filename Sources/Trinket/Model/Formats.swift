import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The formats a Convert stage may offer. Only image formats are ever offered for an image —
/// never "Word (docx)" in a PNG's menu. Each kind has its own type; that is the type system doing
/// the work the old flat settings object could not.

// MARK: - Images

enum ImageFormat: String, Codable, CaseIterable, Identifiable {
    case keep, jpeg, png, heic, tiff

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keep: return "Keep format"
        case .jpeg: return "JPEG"
        case .png:  return "PNG"
        case .heic: return "HEIC"
        case .tiff: return "TIFF"
        }
    }

    /// The one-line "why you'd pick this" the picker shows beside the name.
    var note: String {
        switch self {
        case .keep: return "each image stays what it is"
        case .jpeg: return "widely readable"
        case .png:  return "lossless, larger"
        case .heic: return "smallest, Apple-native"
        case .tiff: return "lossless, archival"
        }
    }

    var utType: UTType? {
        switch self {
        case .keep: return nil
        case .jpeg: return .jpeg
        case .png:  return .png
        case .heic: return .heic
        case .tiff: return .tiff
        }
    }

    var fileExtension: String? {
        switch self {
        case .keep: return nil
        case .jpeg: return "jpg"
        case .png:  return "png"
        case .heic: return "heic"
        case .tiff: return "tiff"
        }
    }

    /// Quality is meaningless for a lossless codec; the stage hides the slider rather than
    /// showing a control that does nothing.
    var isLossy: Bool { self == .jpeg || self == .heic }

    /// Offered only if ImageIO on *this* machine says it can write it. Asking is cheaper than
    /// carrying a table of OS versions, and it cannot drift.
    static var writable: [ImageFormat] {
        let supported = Set((CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []))
        return allCases.filter { format in
            guard let type = format.utType else { return true }
            return supported.contains(type.identifier)
        }
    }
}

// MARK: - Documents

enum DocumentFormat: String, Codable, CaseIterable, Identifiable {
    case keep, pdf, text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keep: return "Keep format"
        case .pdf:  return "PDF"
        case .text: return "Plain text"
        }
    }

    var note: String {
        switch self {
        case .keep: return "re-save at a smaller size"
        case .pdf:  return "one portable document"
        case .text: return "text only, everything else dropped"
        }
    }

    var fileExtension: String? {
        switch self {
        case .keep: return nil
        case .pdf:  return "pdf"
        case .text: return "txt"
        }
    }
}

// MARK: - Audio

enum AudioFormat: String, Codable, CaseIterable, Identifiable {
    case keep, aac, mp3, flac, alac, wav, aiff, opus, vorbis

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keep:   return "Keep format"
        case .aac:    return "AAC (m4a)"
        case .mp3:    return "MP3"
        case .flac:   return "FLAC"
        case .alac:   return "Apple Lossless"
        case .wav:    return "WAV"
        case .aiff:   return "AIFF"
        case .opus:   return "Opus"
        case .vorbis: return "Ogg Vorbis"
        }
    }

    var note: String {
        switch self {
        case .keep:   return "re-encode at a smaller size"
        case .aac:    return "small, plays everywhere Apple does"
        case .mp3:    return "plays absolutely everywhere"
        case .flac:   return "lossless, open"
        case .alac:   return "lossless, Apple-native"
        case .wav:    return "uncompressed"
        case .aiff:   return "uncompressed, Apple-native"
        case .opus:   return "smallest at low bitrates"
        case .vorbis: return "open, pre-Opus"
        }
    }

    var fileExtension: String? {
        switch self {
        case .keep:   return nil
        case .aac:    return "m4a"
        case .mp3:    return "mp3"
        case .flac:   return "flac"
        case .alac:   return "m4a"
        case .wav:    return "wav"
        case .aiff:   return "aiff"
        case .opus:   return "opus"
        case .vorbis: return "ogg"
        }
    }

    var isLossy: Bool {
        switch self {
        case .aac, .mp3, .opus, .vorbis: return true
        case .keep, .flac, .alac, .wav, .aiff: return false
        }
    }

    /// `afconvert` cannot write the Ogg container at all, and has no MP3 encoder. Those three go
    /// through ffmpeg or they do not go at all.
    var needsFFmpeg: Bool {
        switch self {
        case .mp3, .opus, .vorbis: return true
        default: return false
        }
    }

    static var available: [AudioFormat] {
        allCases.filter { Shell.hasFFmpeg || !$0.needsFFmpeg }
    }
}

// MARK: - Video

enum VideoFormat: String, Codable, CaseIterable, Identifiable {
    case keep, h264, hevc, webm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keep: return "Keep format"
        case .h264: return "H.264 (mp4)"
        case .hevc: return "HEVC (mp4)"
        case .webm: return "WebM (VP9)"
        }
    }

    var note: String {
        switch self {
        case .keep: return "re-encode at a smaller size"
        case .h264: return "plays everywhere"
        case .hevc: return "about half the size, newer players"
        case .webm: return "open, for the web"
        }
    }

    var fileExtension: String? {
        switch self {
        case .keep: return nil
        case .h264, .hevc: return "mp4"
        case .webm: return "webm"
        }
    }

    /// Every video path is ffmpeg. Without it the whole stage is absent, not disabled.
    var needsFFmpeg: Bool { true }

    static var available: [VideoFormat] { Shell.hasFFmpeg ? allCases : [] }
}

// MARK: - Self-check

enum Formats {
    static func selfCheck() {
        // Keep must be first in every picker — it is the pre-answered default.
        assert(ImageFormat.allCases.first == .keep)
        assert(AudioFormat.allCases.first == .keep)
        assert(VideoFormat.allCases.first == .keep)
        assert(DocumentFormat.allCases.first == .keep)

        // `keep` never names an extension; every other case must.
        assert(ImageFormat.keep.fileExtension == nil)
        for format in ImageFormat.allCases where format != .keep {
            assert(format.fileExtension != nil, "\(format) has no extension")
            assert(format.utType != nil, "\(format) has no UTType")
        }
        for format in AudioFormat.allCases where format != .keep {
            assert(format.fileExtension != nil, "\(format) has no extension")
        }

        // ImageIO must at minimum be able to write the two the planner falls back on.
        let writable = ImageFormat.writable
        assert(writable.contains(.jpeg) && writable.contains(.png),
               "ImageIO cannot write JPEG or PNG — the image engine has no fallback")

        // The three ffmpeg-only audio formats stay hidden when ffmpeg did not ship.
        if !Shell.hasFFmpeg {
            assert(!AudioFormat.available.contains(.mp3), "MP3 offered without an encoder for it")
            assert(VideoFormat.available.isEmpty, "video offered without ffmpeg")
        }
        assert(AudioFormat.available.contains(.aac), "afconvert always gives us AAC")
    }
}
