import Foundation

/// Scrub is not a stage. It is a guarantee that rides along any stage that rewrites a file, shown
/// in the sidebar footer with its four levels and a "what was found" disclosure. A scrub nobody
/// can see is just a promise.
enum ScrubLevel: String, Codable, CaseIterable, Identifiable {
    case keepEverything, locationOnly, shareSafe, nothingButPixels

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keepEverything:    return "Keep everything"
        case .locationOnly:      return "Location only"
        case .shareSafe:         return "Share-safe"
        case .nothingButPixels:  return "Nothing but pixels"
        }
    }

    var explanation: String {
        switch self {
        case .keepEverything:
            return "Nothing removed. Same bytes of metadata as the original."
        case .locationOnly:
            return "Removes GPS. Keeps camera, date & edit history."
        case .shareSafe:
            return "Removes GPS, camera serial & edit history. Keeps orientation & colour profile so it still looks right."
        case .nothingButPixels:
            return "Strips all metadata, including colour profile. Smallest, least portable."
        }
    }

    /// The one-word form the sidebar footer and the finished summary use.
    var shortTitle: String {
        self == .keepEverything ? "Off" : title
    }

    /// What the picker marks "· default". It must be the level a fresh install actually starts
    /// on — a badge next to a level the app is not using is a lie the user can see.
    ///
    /// Nothing-but-pixels rather than share-safe: it also strips the colour profile, which is only
    /// safe because `ImagePass` converts to sRGB *before* dropping the profile. Without that
    /// conversion this default would quietly change how every wide-gamut photo looks.
    static let recommended: ScrubLevel = .nothingButPixels

    var isDefault: Bool { self == Self.recommended }

    /// Whether this level removes a given class of metadata.
    func removes(_ category: MetadataCategory) -> Bool {
        switch self {
        case .keepEverything:
            return false
        case .locationOnly:
            return category == .location
        case .shareSafe:
            // The contract names three removals and two keeps, and is silent on the rest. The
            // line it draws is *what leaks beyond what the picture shows*: where you were, which
            // body shot it, what you did to it, what the frame looked like before you cropped,
            // and which app touched it. The capture date and the author's own byline are things
            // the user put there on purpose, so they stay. Orientation and the colour profile
            // stay or the picture comes out sideways and grey.
            switch category {
            case .location, .cameraSerial, .editHistory, .embeddedThumbnail, .software:
                return true
            case .timestamps, .author, .orientation, .colourProfile:
                return false
            }
        case .nothingButPixels:
            // Orientation is baked into the pixels before it is dropped, so the picture survives.
            return category != .orientation
        }
    }
}

/// A class of metadata trinket can find and name. The inspector lists these; each carries a
/// REMOVE or KEEP tag under the level in force, so removal is verifiable before it happens.
enum MetadataCategory: String, CaseIterable, Codable, Identifiable {
    case location
    case cameraSerial
    case editHistory
    case embeddedThumbnail
    case author
    case timestamps
    case software
    case colourProfile
    case orientation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .location:           return "GPS coordinates"
        case .cameraSerial:       return "Camera serial no."
        case .editHistory:        return "Edit history"
        case .embeddedThumbnail:  return "Thumbnail of uncropped original"
        case .author:             return "Author & copyright"
        case .timestamps:         return "Capture date & time"
        case .software:           return "Software that touched it"
        case .colourProfile:      return "Colour profile"
        case .orientation:        return "Orientation"
        }
    }

    /// How alarming this is when found. Drives the dot beside the row: red is a real disclosure
    /// of where you were or what the original looked like; amber is identifying but not locating.
    enum Severity { case high, medium, low }

    var severity: Severity {
        switch self {
        case .location, .embeddedThumbnail: return .high
        case .cameraSerial, .editHistory, .author, .software: return .medium
        case .timestamps, .colourProfile, .orientation: return .low
        }
    }
}

/// One line of the "what was found" table: a category and how many files carry it.
struct MetadataFinding: Identifiable, Equatable {
    let category: MetadataCategory
    var fileCount: Int
    /// A human-readable sample of the actual value, when showing it is the point — the GPS pair,
    /// the camera serial. Nil when naming the category is enough.
    var sample: String?

    var id: String { category.rawValue }
}

/// The whole report for a batch. Built before the run so the user sees it before removal.
struct ScrubReport: Equatable {
    var findings: [MetadataFinding] = []
    var filesScanned: Int = 0

    var isEmpty: Bool { findings.isEmpty }

    /// Findings sorted the way the inspector shows them: most alarming first, then by count.
    var ordered: [MetadataFinding] {
        findings.sorted { a, b in
            let rank: (MetadataCategory.Severity) -> Int = {
                switch $0 { case .high: return 0; case .medium: return 1; case .low: return 2 }
            }
            let ra = rank(a.category.severity), rb = rank(b.category.severity)
            return ra == rb ? a.fileCount > b.fileCount : ra < rb
        }
    }

    func removed(at level: ScrubLevel) -> [MetadataFinding] {
        ordered.filter { level.removes($0.category) }
    }

    /// The sidebar's one-line summary after a run: "Removed GPS from 18 photos & camera serials
    /// from 22." Nil when nothing was removed, so the UI can say nothing rather than say zero.
    func summary(at level: ScrubLevel) -> String? {
        let removed = self.removed(at: level)
        guard !removed.isEmpty else { return nil }
        let phrases = removed.prefix(2).map { finding -> String in
            switch finding.category {
            case .location: return "GPS from \(finding.fileCount) \(finding.fileCount == 1 ? "file" : "files")"
            case .cameraSerial: return "camera serials from \(finding.fileCount)"
            default: return "\(finding.category.title.lowercased()) from \(finding.fileCount)"
            }
        }
        return "Removed " + phrases.joined(separator: " & ") + "."
    }

    static func selfCheck() {
        let report = ScrubReport(findings: [
            MetadataFinding(category: .cameraSerial, fileCount: 22, sample: nil),
            MetadataFinding(category: .location, fileCount: 18, sample: "51.5074, -0.1278"),
            MetadataFinding(category: .colourProfile, fileCount: 22, sample: "Display P3"),
            MetadataFinding(category: .editHistory, fileCount: 7, sample: nil),
        ], filesScanned: 22)

        // High severity first: GPS and the uncropped thumbnail lead, whatever their counts.
        assert(report.ordered.first?.category == .location,
               "the inspector must lead with what actually locates the user")

        // Share-safe: GPS, serial and history go; the colour profile stays or it looks wrong.
        let shared = report.removed(at: .shareSafe).map(\.category)
        assert(shared.contains(.location) && shared.contains(.cameraSerial) && shared.contains(.editHistory))
        assert(!shared.contains(.colourProfile), "share-safe must keep the colour profile")

        // The embedded thumbnail is the whole demo — a JPEG carries a picture of the *uncropped*
        // original, so cropping someone out of a photo and sharing it leaks them anyway. It must
        // never survive share-safe.
        assert(ScrubLevel.shareSafe.removes(.embeddedThumbnail))
        assert(ScrubLevel.shareSafe.removes(.software))
        // …but the date and the byline are things the user put there on purpose.
        assert(!ScrubLevel.shareSafe.removes(.timestamps))
        assert(!ScrubLevel.shareSafe.removes(.author))
        // Nothing-but-pixels takes both.
        assert(ScrubLevel.nothingButPixels.removes(.timestamps))
        assert(ScrubLevel.nothingButPixels.removes(.author))

        // Location only touches exactly one thing.
        assert(report.removed(at: .locationOnly).map(\.category) == [.location])

        // Keep everything removes nothing, and so has nothing to summarise.
        assert(report.removed(at: .keepEverything).isEmpty)
        assert(report.summary(at: .keepEverything) == nil)

        // Nothing but pixels takes the colour profile too, but never orientation — the picture
        // must not come out sideways.
        assert(ScrubLevel.nothingButPixels.removes(.colourProfile))
        assert(!ScrubLevel.nothingButPixels.removes(.orientation))
        assert(!ScrubLevel.shareSafe.removes(.orientation))

        assert(report.summary(at: .shareSafe) == "Removed GPS from 18 files & camera serials from 22.")
        // The "· default" badge must sit on the level a fresh install really uses, or the UI
        // is telling the user something untrue about their own app.
        assert(ScrubLevel.recommended == Defaults.Factory.scrubLevel,
               "the picker's default badge and the shipped default have drifted apart")
        assert(ScrubLevel.recommended.isDefault)
    }
}
