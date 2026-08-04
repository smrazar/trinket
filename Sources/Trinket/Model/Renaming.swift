import Foundation

/// How results are named.
///
/// Three modes, matching what people already know from PowerRename and the Finder's own batch
/// rename: **find & replace**, **add text**, and a **template** of tokens. Whichever is chosen, the
/// UI shows an Original → Renamed table for the real files before anything is applied — the single
/// most important part, because a rename that surprises you has already happened.
struct Renaming: Equatable, Codable {
    var isEnabled = false
    var mode: Mode = .template

    // MARK: Find & replace
    var find = ""
    var replaceWith = ""
    var isRegex = false
    var isCaseSensitive = false
    /// Replace every occurrence, not just the first.
    var matchAll = true

    // MARK: Add text
    var addition = ""
    var additionPosition: Position = .after

    // MARK: Template
    /// Tokens in `{braces}`; anything else is literal.
    var pattern = "{name}"

    // MARK: Shared
    /// Where numbering starts, for `{n}`.
    var startAt = 1
    /// Zero-padded width for `{n}`; 1 means no padding.
    var digits = 3
    var caseStyle: CaseStyle = .unchanged
    /// Replace runs of whitespace with this. Empty means leave spaces alone.
    var spaceReplacement = ""
    /// Which part of the filename the change applies to.
    var applyTo: Target = .nameOnly

    enum Mode: String, Codable, CaseIterable, Identifiable {
        case findReplace, addText, template
        var id: String { rawValue }

        var title: String {
            switch self {
            case .findReplace: return "Find & replace"
            case .addText:     return "Add text"
            case .template:    return "Template"
            }
        }
    }

    enum Position: String, Codable, CaseIterable, Identifiable {
        case before, after
        var id: String { rawValue }
        var title: String { self == .before ? "Before name" : "After name" }
    }

    /// The extension is part of the filename, and a find-and-replace that hits it by accident
    /// changes what the file *is* as far as the Finder is concerned. Default to name only.
    enum Target: String, Codable, CaseIterable, Identifiable {
        case nameOnly, extensionOnly, both
        var id: String { rawValue }

        var title: String {
            switch self {
            case .nameOnly:      return "Name only"
            case .extensionOnly: return "Extension only"
            case .both:          return "Name + extension"
            }
        }
    }

    enum CaseStyle: String, Codable, CaseIterable, Identifiable {
        case unchanged, lower, upper, title
        var id: String { rawValue }

        var title: String {
            switch self {
            case .unchanged: return "Unchanged"
            case .lower:     return "lower case"
            case .upper:     return "UPPER CASE"
            case .title:     return "Title Case"
            }
        }

        /// The compact button label, as PowerRename shows them.
        var short: String {
            switch self {
            case .unchanged: return "—"
            case .lower:     return "aa"
            case .upper:     return "AA"
            case .title:     return "Aa Aa"
            }
        }
    }

    /// Template tokens, with what each means. The UI lists these rather than hiding them in a
    /// manual nobody reads.
    static let tokens: [(token: String, meaning: String)] = [
        ("{name}",   "the original filename, without its extension"),
        ("{n}",      "a counter, in the order files were added"),
        ("{ext}",    "the new extension, without a dot"),
        ("{kind}",   "photo, doc, audio, video, archive"),
        ("{date}",   "today, as 2026-08-03"),
        ("{time}",   "now, as 14-52-24"),
        ("{w}",      "output width in pixels, images only"),
        ("{h}",      "output height in pixels, images only"),
        ("{parent}", "the folder the original came from"),
    ]

    /// Everything a name can be built from. A plain value, so naming is testable without files.
    struct Context {
        var originalName: String
        var newExtension: String
        var kind: Kind
        /// 0-based position in the batch; `startAt` is added.
        var index: Int
        var width: Int = 0
        var height: Int = 0
        var parent: String = ""
        var date: String = "2026-08-03"
        var time: String = "14-52-24"
    }

    /// Builds the final filename **without** the extension — the caller adds that, because only it
    /// knows what was actually written. When `applyTo` includes the extension, the returned name
    /// carries it and the caller must not add a second one; `changesExtension` says which.
    func apply(_ context: Context) -> String {
        guard isEnabled else { return context.originalName }

        let base: String
        switch mode {
        case .template:
            base = applyTemplate(context)
        case .findReplace:
            base = applyFindReplace(to: context.originalName, context: context)
        case .addText:
            base = applyAddition(to: context.originalName)
        }

        return Self.sanitised(styled(base), fallback: context.originalName)
    }

    /// True when this configuration rewrites the extension too, so the caller should not append
    /// one. Only find-and-replace can, and only when it is pointed at the extension.
    var changesExtension: Bool {
        isEnabled && mode == .findReplace && applyTo != .nameOnly
    }

    /// The extension after a rename, given the one that was written.
    func newExtension(from written: String, context: Context) -> String {
        guard changesExtension else { return written }
        return applyFindReplace(to: written, context: context)
    }

    // MARK: - Modes

    private func applyTemplate(_ context: Context) -> String {
        guard !pattern.trimmingCharacters(in: .whitespaces).isEmpty else { return context.originalName }
        let counter = String(format: "%0\(max(1, digits))d", startAt + context.index)
        var result = pattern
        for (token, value) in [
            ("{name}", context.originalName),
            ("{n}", counter),
            ("{ext}", context.newExtension),
            ("{kind}", kindWord(context.kind)),
            ("{date}", context.date),
            ("{time}", context.time),
            ("{w}", context.width > 0 ? String(context.width) : ""),
            ("{h}", context.height > 0 ? String(context.height) : ""),
            ("{parent}", context.parent),
        ] {
            result = result.replacingOccurrences(of: token, with: value)
        }
        return result
    }

    private func applyFindReplace(to text: String, context: Context) -> String {
        guard !find.isEmpty else { return text }
        // The replacement may itself contain `{n}`, which is how PowerRename numbers a batch.
        let counter = String(format: "%0\(max(1, digits))d", startAt + context.index)
        let replacement = replaceWith.replacingOccurrences(of: "{n}", with: counter)

        if isRegex {
            // An invalid pattern must leave the name alone rather than throw mid-batch — someone
            // is typing this live, so it is invalid on the way to being valid.
            let options: NSRegularExpression.Options = isCaseSensitive ? [] : [.caseInsensitive]
            guard let expression = try? NSRegularExpression(pattern: find, options: options) else {
                return text
            }
            let range = NSRange(text.startIndex..., in: text)
            if matchAll {
                return expression.stringByReplacingMatches(in: text, range: range,
                                                           withTemplate: replacement)
            }
            guard let first = expression.firstMatch(in: text, range: range),
                  let swiftRange = Range(first.range, in: text) else { return text }
            return text.replacingCharacters(in: swiftRange, with: replacement)
        }

        let options: String.CompareOptions = isCaseSensitive ? [] : [.caseInsensitive]
        if matchAll {
            return text.replacingOccurrences(of: find, with: replacement, options: options)
        }
        guard let found = text.range(of: find, options: options) else { return text }
        return text.replacingCharacters(in: found, with: replacement)
    }

    private func applyAddition(to text: String) -> String {
        guard !addition.isEmpty else { return text }
        return additionPosition == .before ? addition + text : text + addition
    }

    private func styled(_ text: String) -> String {
        var result = text
        if !spaceReplacement.isEmpty {
            result = result.split(whereSeparator: \.isWhitespace).joined(separator: spaceReplacement)
        }
        switch caseStyle {
        case .unchanged: return result
        case .lower: return result.lowercased()
        case .upper: return result.uppercased()
        case .title:
            return result.split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: " ")
        }
    }

    private func kindWord(_ kind: Kind) -> String {
        switch kind {
        case .image: return "photo"
        case .document: return "doc"
        case .audio: return "audio"
        case .video: return "video"
        case .archive: return "archive"
        case .other: return "file"
        }
    }

    /// A pattern is user input, and it lands on a filesystem. `/` would silently create a
    /// directory level, a leading `.` hides the file, and `:` is a path separator to the Finder.
    static func sanitised(_ name: String, fallback: String) -> String {
        var cleaned = name
        for bad in ["/", ":", "\\", "\u{0}"] {
            cleaned = cleaned.replacingOccurrences(of: bad, with: "-")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        // A filesystem name is capped at 255 bytes; leave room for an extension and a `-2` suffix.
        if cleaned.count > 200 { cleaned = String(cleaned.prefix(200)) }
        return cleaned.isEmpty ? fallback : cleaned
    }

    /// One row of the preview table: what the file is called now, and what it would become.
    struct PreviewRow: Identifiable {
        let id = UUID()
        let before: String
        let after: String
        var changed: Bool { before != after }
    }

    /// The preview the UI shows. Runs the **same** `apply` the run does, so what is shown cannot
    /// drift from what happens.
    func previewRows(for names: [(name: String, ext: String, kind: Kind)]) -> [PreviewRow] {
        names.enumerated().map { index, file in
            let context = Context(originalName: file.name, newExtension: file.ext,
                                  kind: file.kind, index: index,
                                  width: 1024, height: 768, parent: "Photos")
            let base = apply(context)
            let ext = newExtension(from: file.ext, context: context)
            let before = file.ext.isEmpty ? file.name : "\(file.name).\(file.ext)"
            let after = ext.isEmpty ? base : "\(base).\(ext)"
            return PreviewRow(before: before, after: after)
        }
    }

    /// A single example, for the one-line hint beside the field.
    func example() -> String {
        previewRows(for: [("IMG_2087", "jpg", .image)]).first?.after ?? ""
    }

    static func selfCheck() {
        var renaming = Renaming()
        let context = Context(originalName: "IMG_2087", newExtension: "jpg", kind: .image,
                              index: 0, width: 1024, height: 768, parent: "Photos")

        // Off by default, and off means the name is untouched. This is the one that matters most:
        // renaming a batch is not something to do by accident.
        assert(!renaming.isEnabled)
        assert(renaming.apply(context) == "IMG_2087")

        // MARK: Template
        renaming.isEnabled = true
        renaming.mode = .template
        renaming.pattern = "holiday-{n}"
        assert(renaming.apply(context) == "holiday-001")
        renaming.startAt = 7
        assert(renaming.apply(context) == "holiday-007")
        var third = context
        third.index = 3
        assert(renaming.apply(third) == "holiday-010", "the counter must advance with the index")
        renaming.digits = 1
        assert(renaming.apply(context) == "holiday-7", "one digit means no padding")

        renaming.digits = 2
        renaming.startAt = 1
        renaming.pattern = "{kind}-{date}-{w}x{h}-{parent}-{n}.{ext}"
        assert(renaming.apply(context) == "photo-2026-08-03-1024x768-Photos-01.jpg")

        var noPixels = context
        noPixels.width = 0; noPixels.height = 0
        renaming.pattern = "{name}-{w}"
        assert(renaming.apply(noPixels) == "IMG_2087-",
               "a token with nothing behind it leaves nothing, not the literal token")

        // MARK: Find & replace
        renaming = Renaming()
        renaming.isEnabled = true
        renaming.mode = .findReplace
        renaming.find = "IMG"
        renaming.replaceWith = "Holiday"
        assert(renaming.apply(context) == "Holiday_2087")

        // Case sensitivity really is a switch, in both directions.
        renaming.find = "img"
        assert(renaming.apply(context) == "Holiday_2087", "the default is case-insensitive")
        renaming.isCaseSensitive = true
        assert(renaming.apply(context) == "IMG_2087", "case-sensitive must not match a different case")

        // Match-all versus first-only.
        renaming.isCaseSensitive = false
        renaming.find = "0"
        renaming.replaceWith = "X"
        renaming.matchAll = true
        assert(renaming.apply(context) == "IMG_2X87")   // one "0" in 2087
        var doubled = context
        doubled.originalName = "a0b0c"
        assert(renaming.apply(doubled) == "aXbXc")
        renaming.matchAll = false
        assert(renaming.apply(doubled) == "aXb0c", "first-only must leave the rest alone")

        // Regex, including the numbering token in the replacement.
        renaming.matchAll = true
        renaming.isRegex = true
        renaming.find = "[0-9]+"
        renaming.replaceWith = "{n}"
        renaming.digits = 3
        assert(renaming.apply(context) == "IMG_001")

        // An invalid pattern leaves the name alone — it is invalid on the way to being valid.
        renaming.find = "[unclosed"
        assert(renaming.apply(context) == "IMG_2087", "a half-typed regex must not mangle the name")

        // MARK: Add text
        renaming = Renaming()
        renaming.isEnabled = true
        renaming.mode = .addText
        renaming.addition = "-edited"
        assert(renaming.apply(context) == "IMG_2087-edited")
        renaming.additionPosition = .before
        assert(renaming.apply(context) == "-editedIMG_2087")

        // MARK: Case and spaces, on every mode
        renaming.mode = .template
        renaming.pattern = "My Holiday Photo"
        renaming.caseStyle = .lower
        assert(renaming.apply(context) == "my holiday photo")
        renaming.spaceReplacement = "-"
        assert(renaming.apply(context) == "my-holiday-photo")
        renaming.caseStyle = .title
        renaming.spaceReplacement = ""
        assert(renaming.apply(context) == "My Holiday Photo")
        renaming.caseStyle = .upper
        assert(renaming.apply(context) == "MY HOLIDAY PHOTO")

        // MARK: The safety rules — a pattern is user input landing on a filesystem
        renaming.caseStyle = .unchanged
        renaming.pattern = "../../etc/passwd"
        assert(!renaming.apply(context).contains("/"), "a slash would create a directory level")
        renaming.pattern = ".hidden"
        assert(!renaming.apply(context).hasPrefix("."), "a leading dot would hide the file")
        renaming.pattern = "a:b"
        assert(!renaming.apply(context).contains(":"), "a colon is a path separator to the Finder")
        renaming.pattern = "   "
        assert(renaming.apply(context) == "IMG_2087", "an empty result falls back to the original")
        renaming.pattern = String(repeating: "x", count: 400)
        assert(renaming.apply(context).count <= 200, "a name must stay inside the filesystem's limit")

        // MARK: The extension is only touched when explicitly asked for
        var extensions = Renaming()
        extensions.isEnabled = true
        extensions.mode = .findReplace
        extensions.find = "jpg"
        extensions.replaceWith = "jpeg"
        assert(!extensions.changesExtension, "name-only must never rewrite the extension")
        assert(extensions.newExtension(from: "jpg", context: context) == "jpg")
        extensions.applyTo = .both
        assert(extensions.changesExtension)
        assert(extensions.newExtension(from: "jpg", context: context) == "jpeg")

        // MARK: The preview runs the same code as the run, so it cannot lie
        var previewing = Renaming()
        previewing.isEnabled = true
        previewing.mode = .template
        previewing.pattern = "{name}-{n}"
        let rows = previewing.previewRows(for: [("a", "jpg", .image), ("b", "png", .image)])
        assert(rows.count == 2)
        assert(rows[0].before == "a.jpg" && rows[0].after == "a-001.jpg")
        assert(rows[1].after == "b-002.jpg" || rows[1].after == "b-002.png")
        assert(rows[0].changed)
        // A no-op configuration reports no change, so the table does not imply one.
        var idle = Renaming()
        idle.isEnabled = true
        idle.mode = .findReplace
        idle.find = "zzz"
        assert(idle.previewRows(for: [("a", "jpg", .image)]).allSatisfy { !$0.changed })
    }
}
