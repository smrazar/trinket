import Foundation
import AppKit
import ImageIO
import CoreGraphics

/// Pulls the *stored* thumbnail out of a JPEG — the small copy of the frame before it was
/// cropped, which travels with every share of the file.
///
/// This has to read the bytes itself for the same reason `MetadataPass.hasEmbeddedThumbnail` does:
/// ImageIO's thumbnail API renders one from the full image when none is stored, so asking it
/// would hand back a shrunken copy of the picture already on screen and the comparison would show
/// two identical images — the exact opposite of the point.
enum ThumbnailExtractor {

    static func embeddedThumbnail(in url: URL) -> NSImage? {
        guard let data = thumbnailData(in: url) else { return nil }
        return NSImage(data: data)
    }

    /// The raw JPEG bytes of the stored thumbnail, if there is one.
    static func thumbnailData(in url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 512 * 1024), head.count > 4 else { return nil }
        let bytes = [UInt8](head)
        guard bytes.count > 2, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }

        var index = 2
        while index + 4 < bytes.count {
            guard bytes[index] == 0xFF else { index += 1; continue }
            let marker = bytes[index + 1]
            if marker == 0xFF || marker == 0x01 || (0xD0...0xD8).contains(marker) {
                index += 2
                continue
            }
            if marker == 0xDA || marker == 0xD9 { return nil }

            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            guard length >= 2 else { return nil }

            if marker == 0xE1, index + 10 <= bytes.count,
               bytes[index + 4] == 0x45, bytes[index + 5] == 0x78,
               bytes[index + 6] == 0x69, bytes[index + 7] == 0x66 {
                if let extracted = extract(bytes, tiffStart: index + 10) { return extracted }
            }
            index += 2 + length
        }
        return nil
    }

    /// Walks to IFD1 and reads tags 0x0201 (offset) and 0x0202 (length). Both offsets are
    /// relative to the TIFF header, not the file.
    private static func extract(_ bytes: [UInt8], tiffStart: Int) -> Data? {
        guard tiffStart + 8 <= bytes.count else { return nil }
        let isLittleEndian = bytes[tiffStart] == 0x49

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

        guard u16(tiffStart + 2) == 42 else { return nil }
        let ifd0 = tiffStart + u32(tiffStart + 4)
        guard ifd0 + 2 <= bytes.count else { return nil }
        let entryCount = u16(ifd0)
        guard entryCount < 4096 else { return nil }

        let nextPointer = u32(ifd0 + 2 + entryCount * 12)
        guard nextPointer != 0 else { return nil }
        let ifd1 = tiffStart + nextPointer
        guard ifd1 + 2 <= bytes.count else { return nil }
        let thumbnailEntries = u16(ifd1)
        guard thumbnailEntries > 0, thumbnailEntries < 4096 else { return nil }

        var offset: Int?
        var length: Int?
        for entry in 0..<thumbnailEntries {
            let base = ifd1 + 2 + entry * 12
            switch u16(base) {
            case 0x0201: offset = u32(base + 8)
            case 0x0202: length = u32(base + 8)
            default: break
            }
        }

        guard let offset, let length, length > 0 else { return nil }
        let start = tiffStart + offset
        let end = start + length
        // A corrupt or truncated header must not index past the buffer.
        guard start >= 0, end <= bytes.count, start < end else { return nil }
        return Data(bytes[start..<end])
    }

    static func selfCheck() {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "trinket-thumb-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // A file with no stored thumbnail must yield nothing — not a re-rendered copy of itself,
        // which is what ImageIO would hand back and what would make the comparison meaningless.
        let plain = folder.appending(path: "plain.jpg")
        if let context = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8,
                                   bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            context.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
            if let image = context.makeImage(),
               let destination = CGImageDestinationCreateWithURL(
                   plain as CFURL, "public.jpeg" as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, [:] as CFDictionary)
                _ = CGImageDestinationFinalize(destination)
            }
        }
        assert(thumbnailData(in: plain) == nil,
               "a file with no stored thumbnail must yield nothing, not a rendered copy")

        // A file that has one yields real JPEG bytes.
        let embedded = folder.appending(path: "embedded.jpg")
        if let context = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8,
                                   bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            context.setFillColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
            if let image = context.makeImage(),
               let destination = CGImageDestinationCreateWithURL(
                   embedded as CFURL, "public.jpeg" as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image,
                                           [kCGImageDestinationEmbedThumbnail: true] as CFDictionary)
                _ = CGImageDestinationFinalize(destination)
            }
        }
        if let data = thumbnailData(in: embedded) {
            assert(data.count > 2, "the extracted thumbnail is empty")
            assert(data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0xD8,
                   "the extracted bytes are not a JPEG")
            assert(NSImage(data: data) != nil, "the extracted thumbnail does not decode")
        } else {
            assertionFailure("a JPEG written with an embedded thumbnail yielded none")
        }

        // Garbage in must not crash or read past the buffer.
        let junk = folder.appending(path: "junk.jpg")
        try? Data([0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0xFF, 0x45, 0x78, 0x69, 0x66]).write(to: junk)
        _ = thumbnailData(in: junk)
    }
}
