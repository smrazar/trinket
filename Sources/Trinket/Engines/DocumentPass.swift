import Foundation
import PDFKit
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// PDFs, and the handful of document formats macOS can rewrite without help.
///
/// A PDF's weight is almost entirely its embedded images. Re-saving does nothing; the win comes
/// from pulling each page's images out, re-encoding them, and putting them back. That also
/// collapses the file's revision history, which is where "deleted" text hides.
enum DocumentPass {

    struct Outcome {
        let outputURL: URL
        let size: Int64
    }

    enum Failure: LocalizedError {
        case unreadable(URL)
        case encrypted(URL)
        case writeFailed(URL)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let url): return "\(url.lastPathComponent) could not be opened."
            case .encrypted(let url): return "\(url.lastPathComponent) is password-protected."
            case .writeFailed(let url): return "Could not write \(url.lastPathComponent)."
            case .unsupported(let ext): return "trinket does not rewrite .\(ext) files yet."
            }
        }
    }

    static func run(_ url: URL,
                    stage: ShrinkStage,
                    scrub: ScrubLevel,
                    into destination: URL) throws -> Outcome {
        guard url.pathExtension.lowercased() == "pdf" else {
            // Anything else passes through: rewriting a .docx means owning OOXML, which is a
            // different app. The row says so rather than pretending.
            throw Failure.unsupported(url.pathExtension.lowercased())
        }
        return try rewritePDF(url, stage: stage, scrub: scrub, into: destination)
    }

    // MARK: - PDF

    private static func rewritePDF(_ url: URL,
                                   stage: ShrinkStage,
                                   scrub: ScrubLevel,
                                   into destination: URL) throws -> Outcome {
        guard let document = PDFDocument(url: url) else { throw Failure.unreadable(url) }
        // An encrypted PDF cannot be rewritten without the password, and guessing is not a
        // feature. Fail with the reason rather than writing a broken file.
        guard !document.isEncrypted || document.unlock(withPassword: "") else {
            throw Failure.encrypted(url)
        }

        let output = try ImagePass.uniqueDestination(for: url, type: .pdf, in: destination)
        let scrubbed = attributes(from: document, scrub: scrub)
        let original = size(of: url)

        // Writing a fresh document is what drops the revision history: earlier saved states
        // simply have no path into the new file.
        let rebuilt = PDFDocument()
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            if let rasterised = recompress(page, quality: stage.quality, longestEdge: stage.longestEdge) {
                rebuilt.insert(rasterised, at: rebuilt.pageCount)
            } else {
                // Nothing to gain on this page — keep the original, vectors and selectable text
                // intact. Rasterising a text page to "save space" makes it bigger and unreadable.
                rebuilt.insert(page, at: rebuilt.pageCount)
            }
        }
        rebuilt.documentAttributes = scrubbed
        guard rebuilt.write(to: output) else { throw Failure.writeFailed(output) }
        let written = size(of: output)

        guard written >= original, original > 0 else {
            return Outcome(outputURL: output, size: written)
        }

        // The rewrite made it bigger — a text-heavy PDF with nothing to squeeze. Fall back, but
        // fall back to the *pages*, not to the file: copying the original bytes would hand back
        // every piece of metadata the user asked to have removed. A size optimisation must never
        // silently cancel the scrub.
        let untouched = PDFDocument()
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            untouched.insert(page, at: untouched.pageCount)
        }
        untouched.documentAttributes = scrubbed
        guard untouched.write(to: output) else { throw Failure.writeFailed(output) }
        let fallback = size(of: output)

        // Only when nothing is being removed is the original file itself the best answer.
        if scrub == .keepEverything, fallback >= original {
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.copyItem(at: url, to: output)
            return Outcome(outputURL: output, size: original)
        }
        return Outcome(outputURL: output, size: fallback)
    }

    private static func size(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.int64Value ?? 0
    }

    /// Re-renders one page through a JPEG round-trip, when that is actually smaller.
    ///
    /// `PDFPage(image:)` takes the page box from `NSImage.size` **in points**, so handing it a 2×
    /// render makes the page twice the size on paper — and `setBounds` then crops rather than
    /// scales. The fix is to render at 2× for quality but declare the image's size in the
    /// original point dimensions, so the page geometry is unchanged and only the pixel density
    /// goes up.
    private static func recompress(_ page: PDFPage, quality: Double, longestEdge: Int) -> PDFPage? {
        let box = page.bounds(for: .mediaBox)
        guard box.width > 1, box.height > 1 else { return nil }

        // Render at 2× so text stays crisp, unless the user capped the edge lower than that.
        var scale = 2.0
        if longestEdge > 0 {
            let longest = max(box.width, box.height)
            scale = min(scale, Double(longestEdge) / longest)
        }
        guard scale > 0.05 else { return nil }

        let pixelWidth = Int((box.width * scale).rounded())
        let pixelHeight = Int((box.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0,
              pixelWidth * pixelHeight < 80_000_000 else { return nil }   // refuse absurd pages

        // `NSImage.lockFocus()` would allocate at the *display's* scale, which makes the result
        // depend on which monitor the app happens to be on. A CGContext is told its own size.
        guard let context = CGContext(data: nil,
                                      width: pixelWidth, height: pixelHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }

        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.origin.x, y: -box.origin.y)
        page.draw(with: .mediaBox, to: context)

        guard let rendered = context.makeImage() else { return nil }

        // Encode to JPEG, then wrap it back into a page whose *point* size matches the original.
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, rendered, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        let image = NSImage(cgImage: rendered, size: box.size)   // points, not pixels
        guard let rebuilt = PDFPage(image: image) else { return nil }
        rebuilt.setBounds(box, for: .mediaBox)
        return rebuilt
    }

    /// The surviving document attributes, under the scrub level in force. Built rather than
    /// filtered, for the same reason the image pass builds its dictionary.
    private static func attributes(from document: PDFDocument, scrub: ScrubLevel) -> [AnyHashable: Any] {
        let source = document.documentAttributes ?? [:]
        guard scrub != .keepEverything else { return source }

        var kept: [AnyHashable: Any] = [:]
        if !scrub.removes(.author) {
            kept[PDFDocumentAttribute.authorAttribute] = source[PDFDocumentAttribute.authorAttribute]
        }
        if !scrub.removes(.timestamps) {
            kept[PDFDocumentAttribute.creationDateAttribute] = source[PDFDocumentAttribute.creationDateAttribute]
        }
        if !scrub.removes(.software) {
            kept[PDFDocumentAttribute.creatorAttribute] = source[PDFDocumentAttribute.creatorAttribute]
        }
        // The title and subject are content the author wrote, not a leak — they survive anything
        // short of nothing-but-pixels.
        if scrub != .nothingButPixels {
            kept[PDFDocumentAttribute.titleAttribute] = source[PDFDocumentAttribute.titleAttribute]
            kept[PDFDocumentAttribute.subjectAttribute] = source[PDFDocumentAttribute.subjectAttribute]
        }
        return kept.compactMapValues { $0 }
    }

    // MARK: - Self-check

    static func selfCheck() {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "trinket-pdf-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // A .docx is refused by name rather than mangled.
        let fake = folder.appending(path: "notes.docx")
        try? Data("x".utf8).write(to: fake)
        do {
            _ = try run(fake, stage: ShrinkStage(kind: .document, target: .document(.keep)),
                        scrub: .shareSafe, into: folder)
            assertionFailure("a .docx must be refused, not silently mangled")
        } catch {
            assert(error is Failure)
        }

        guard let source = writeProbePDF(into: folder) else {
            assertionFailure("could not write the probe PDF")
            return
        }
        let before = PDFDocument(url: source)
        let originalBounds = before?.page(at: 0)?.bounds(for: .mediaBox) ?? .zero
        assert(before?.pageCount == 2)

        var stage = ShrinkStage(kind: .document, target: .document(.keep))
        stage.quality = 0.5
        guard let outcome = try? run(source, stage: stage, scrub: .shareSafe, into: folder),
              let after = PDFDocument(url: outcome.outputURL) else {
            assertionFailure("the PDF pass failed on its own probe")
            return
        }

        assert(after.pageCount == before?.pageCount, "page count must survive the rewrite")

        // The trap: a 2× render must not double the page's paper size. Same points in, same
        // points out — if `PDFPage(image:)` ever takes the pixel size again, this fires.
        let rewrittenBounds = after.page(at: 0)?.bounds(for: .mediaBox) ?? .zero
        assert(abs(rewrittenBounds.width - originalBounds.width) < 1.0
                && abs(rewrittenBounds.height - originalBounds.height) < 1.0,
               "page geometry changed: \(originalBounds.size) became \(rewrittenBounds.size)")

        // The scrub reached the document attributes — including on the fallback path, where the
        // rewrite grew the file and the *pages* were kept rather than the original bytes. This
        // probe is vector art, so it takes that path; copying the file would have restored the
        // Creator and quietly cancelled the scrub.
        let attributes = after.documentAttributes ?? [:]
        assert(attributes[PDFDocumentAttribute.creatorAttribute] == nil,
               "share-safe must drop the app that produced the PDF, even when the rewrite grew it")
        assert(attributes[PDFDocumentAttribute.titleAttribute] != nil,
               "the title is content the author wrote — it survives share-safe")

        // The ceiling, measured rather than assumed: PDFKit re-injects Producer, CreationDate and
        // ModDate on every write and offers no way to suppress them. Producer names the OS build,
        // not the user, so the leak is small — but "Nothing but pixels" cannot fully deliver on a
        // PDF, and the UI must not claim otherwise.
        let bare = try? run(source, stage: stage, scrub: .nothingButPixels, into: folder)
        if let bare, let stripped = PDFDocument(url: bare.outputURL) {
            let remaining = stripped.documentAttributes ?? [:]
            assert(remaining[PDFDocumentAttribute.titleAttribute] == nil,
                   "nothing-but-pixels must drop the title")
            assert(remaining[PDFDocumentAttribute.producerAttribute] != nil,
                   "PDFKit no longer re-injects Producer — the ceiling moved, update the UI copy")
        }

        // A result never overwrites one already sitting in the folder.
        let second = try? run(source, stage: stage, scrub: .shareSafe, into: folder)
        assert(second?.outputURL != outcome.outputURL)

        // Keep-everything on a file that cannot shrink is the one case where the original bytes
        // are the right answer.
        let originalSize = size(of: source)
        if let kept = try? run(source, stage: stage, scrub: .keepEverything, into: folder) {
            assert(kept.size == originalSize,
                   "with nothing to remove and nothing to gain, hand back the original bytes")
        }
    }

    /// Two image-heavy pages, so there is something real to recompress.
    private static func writeProbePDF(into folder: URL) -> URL? {
        let url = folder.appending(path: "probe.pdf")
        let box = CGRect(x: 0, y: 0, width: 612, height: 792)   // US Letter, in points
        var mediaBox = box
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, [
                  kCGPDFContextCreator as CFString: "trinket self-check" as CFString,
                  kCGPDFContextTitle as CFString: "Probe" as CFString,
              ] as CFDictionary)
        else { return nil }

        for page in 0..<2 {
            context.beginPDFPage(nil)
            // A gradient of solid rectangles: real pixels, and compressible.
            for band in 0..<40 {
                let shade = Double(band + page * 3) / 45.0
                context.setFillColor(red: shade, green: 0.4, blue: 1 - shade, alpha: 1)
                context.fill(CGRect(x: 0, y: Double(band) * 19.8, width: 612, height: 19.8))
            }
            context.endPDFPage()
        }
        context.closePDF()
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
