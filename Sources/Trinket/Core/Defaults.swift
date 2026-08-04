import Foundation
import SwiftUI

/// Everything that survives a quit. The sidebar carries the settings that change what *this*
/// conversion produces; these are the standing defaults the planner starts from, and they live in
/// the Settings window. A value appearing in both places would read as the same control twice.
///
/// `UserDefaults(suiteName:)` returns nil when the suite is the app's own bundle id, so a check on
/// it passes for a bare binary and fails inside the app. Use `.standard` and nothing else.
@MainActor
final class Defaults: ObservableObject {
    static let shared = Defaults()

    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
        // Read once into published properties; `didSet` writes back. Reading through UserDefaults
        // on every SwiftUI body evaluation is how a preference read ends up in a draw loop.
        hasLaunchedBefore = store.bool(forKey: Key.hasLaunchedBefore)
        imageFormat = store.decode(Key.imageFormat) ?? Factory.imageFormat
        quality = store.contains(Key.quality) ? store.double(forKey: Key.quality) : Factory.quality
        longestEdge = store.contains(Key.longestEdge) ? store.integer(forKey: Key.longestEdge) : Factory.longestEdge
        targetKilobytes = store.contains(Key.targetKilobytes)
            ? store.integer(forKey: Key.targetKilobytes) : Factory.targetKilobytes
        documentFormat = store.decode(Key.documentFormat) ?? Factory.documentFormat
        audioFormat = store.decode(Key.audioFormat) ?? Factory.audioFormat
        videoFormat = store.decode(Key.videoFormat) ?? Factory.videoFormat
        scrubLevel = store.decode(Key.scrubLevel) ?? Factory.scrubLevel
        originalHandling = store.decode(Key.originalHandling) ?? Factory.originalHandling
        outputLocation = store.decode(Key.outputLocation) ?? Factory.outputLocation
        renaming = store.decodeJSON(Key.renaming) ?? Renaming()
        viewMode = store.decode(Key.viewMode) ?? .compact
        outputFolderPath = store.string(forKey: Key.outputFolder) ?? Self.defaultOutputFolder.path
        windowFrost = store.contains(Key.windowFrost) ? store.bool(forKey: Key.windowFrost) : Factory.windowFrost
        floatingResults = store.contains(Key.floatingResults)
            ? store.bool(forKey: Key.floatingResults) : Factory.floatingResults
        showLogSidebar = store.contains(Key.showLogSidebar)
            ? store.bool(forKey: Key.showLogSidebar) : Factory.showLogSidebar
        // Clamped on the way in as well as on the way out: a width saved by an older build, or a
        // hand-edited plist, must not be able to push a pane off the window.
        planSidebarWidth = store.contains(Key.planSidebarWidth)
            ? CGFloat(store.double(forKey: Key.planSidebarWidth)).clampedTo(Tokens.Width.planRange)
            : Tokens.Width.planSidebar
        logSidebarWidth = store.contains(Key.logSidebarWidth)
            ? CGFloat(store.double(forKey: Key.logSidebarWidth)).clampedTo(Tokens.Width.logRange)
            : Tokens.Width.logSidebar
    }

    /// What a fresh install starts with — **the settings the user actually runs**, read off their
    /// own preferences rather than guessed. One place, so the init fallbacks above and
    /// `resetToFactory` below cannot drift apart.
    ///
    /// `outputFolderPath` is deliberately absent: a path is per-machine, so it stays
    /// `~/Downloads/trinket` and `outputLocation` decides whether it is used at all.
    enum Factory {
        /// JPEG rather than "keep": the point of a drop is usually a file someone else can open.
        static let imageFormat: ImageFormat = .jpeg
        static let quality: Double = 0.75
        static let longestEdge = 1024
        /// 250 KB. Aggressive, and the reason the quality slider is a *ceiling* — the encoder
        /// walks down from it until the file fits.
        static let targetKilobytes = 250
        static let documentFormat: DocumentFormat = .keep
        /// MP3 and H.264 travel everywhere, which is what these files are for.
        static let audioFormat: AudioFormat = .mp3
        static let videoFormat: VideoFormat = .h264
        /// Nothing but pixels. Strips the colour profile too, so a wide-gamut photo is converted
        /// to sRGB before the profile goes — see `ImagePass.flattenToSRGB`, without which this
        /// setting would quietly change how every photo looks.
        static let scrubLevel: ScrubLevel = .nothingButPixels
        /// Never touch the user's original by default. The one setting that destroys data.
        static let originalHandling: OriginalHandling = .keep
        static let outputLocation: OutputLocation = .besideOriginal
        static let windowFrost = false
        static let floatingResults = true
        static let showLogSidebar = false
    }

    // MARK: - Stored

    @Published var hasLaunchedBefore: Bool { didSet { store.set(hasLaunchedBefore, forKey: Key.hasLaunchedBefore) } }

    /// Applied to every image unless the plan overrides it.
    @Published var imageFormat: ImageFormat { didSet { store.encode(imageFormat, Key.imageFormat) } }
    /// 0…1. The slider shows it as a percentage.
    @Published var quality: Double { didSet { store.set(quality.clamped(0.1, 1.0), forKey: Key.quality) } }
    /// Longest edge in pixels; 0 means never resize.
    @Published var longestEdge: Int { didSet { store.set(max(0, longestEdge), forKey: Key.longestEdge) } }
    /// Target file size in KB; 0 means off.
    @Published var targetKilobytes: Int { didSet { store.set(max(0, targetKilobytes), forKey: Key.targetKilobytes) } }

    @Published var documentFormat: DocumentFormat { didSet { store.encode(documentFormat, Key.documentFormat) } }
    @Published var audioFormat: AudioFormat { didSet { store.encode(audioFormat, Key.audioFormat) } }
    @Published var videoFormat: VideoFormat { didSet { store.encode(videoFormat, Key.videoFormat) } }

    @Published var scrubLevel: ScrubLevel { didSet { store.encode(scrubLevel, Key.scrubLevel) } }
    @Published var originalHandling: OriginalHandling { didSet { store.encode(originalHandling, Key.originalHandling) } }
    @Published var outputLocation: OutputLocation { didSet { store.encode(outputLocation, Key.outputLocation) } }
    /// How results are named. Off by default: the safe answer is the name the file already had.
    @Published var renaming: Renaming { didSet { store.encodeJSON(renaming, Key.renaming) } }
    /// How the middle panel draws its files.
    @Published var viewMode: ViewMode { didSet { store.encode(viewMode, Key.viewMode) } }
    @Published var outputFolderPath: String { didSet { store.set(outputFolderPath, forKey: Key.outputFolder) } }

    @Published var windowFrost: Bool { didSet { store.set(windowFrost, forKey: Key.windowFrost) } }
    @Published var floatingResults: Bool { didSet { store.set(floatingResults, forKey: Key.floatingResults) } }
    @Published var showLogSidebar: Bool { didSet { store.set(showLogSidebar, forKey: Key.showLogSidebar) } }

    @Published var planSidebarWidth: CGFloat {
        didSet { store.set(Double(planSidebarWidth.clampedTo(Tokens.Width.planRange)), forKey: Key.planSidebarWidth) }
    }
    @Published var logSidebarWidth: CGFloat {
        didSet { store.set(Double(logSidebarWidth.clampedTo(Tokens.Width.logRange)), forKey: Key.logSidebarWidth) }
    }

    // MARK: - Derived

    static let defaultOutputFolder = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(path: "Downloads/trinket", directoryHint: .isDirectory)

    var outputFolder: URL { URL(filePath: outputFolderPath, directoryHint: .isDirectory) }

    /// `~/Downloads/trinket` — the tilde form the Settings window shows.
    var outputFolderDisplay: String {
        outputFolderPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// The starting point for a plan, before the analyser adjusts it per kind.
    var planDefaults: PlanDefaults {
        PlanDefaults(imageFormat: imageFormat,
                     quality: quality,
                     longestEdge: longestEdge,
                     targetKilobytes: targetKilobytes,
                     documentFormat: documentFormat,
                     audioFormat: audioFormat,
                     videoFormat: videoFormat,
                     scrubLevel: scrubLevel)
    }

    func resetToFactory() {
        // `hasLaunchedBefore` survives: resetting settings should not replay the welcome screen.
        for key in Key.all where key != Key.hasLaunchedBefore { store.removeObject(forKey: key) }
        imageFormat = Factory.imageFormat
        quality = Factory.quality
        longestEdge = Factory.longestEdge
        targetKilobytes = Factory.targetKilobytes
        documentFormat = Factory.documentFormat
        audioFormat = Factory.audioFormat
        videoFormat = Factory.videoFormat
        scrubLevel = Factory.scrubLevel
        originalHandling = Factory.originalHandling
        outputLocation = Factory.outputLocation
        renaming = Renaming()
        viewMode = .compact
        outputFolderPath = Self.defaultOutputFolder.path
        windowFrost = Factory.windowFrost
        floatingResults = Factory.floatingResults
        showLogSidebar = Factory.showLogSidebar
        planSidebarWidth = Tokens.Width.planSidebar
        logSidebarWidth = Tokens.Width.logSidebar
    }

    /// Takes the settings a plan is currently running with and makes them the standing defaults,
    /// so the next drop starts there. The sidebar's "Save as my defaults".
    func adopt(_ plan: Blueprint) {
        scrubLevel = plan.scrub
        for lane in plan.lanes {
            guard let shrink = lane.shrink else { continue }
            switch shrink.target {
            case .image(let format):
                imageFormat = format
                quality = shrink.quality
                longestEdge = shrink.longestEdge
                targetKilobytes = shrink.targetKilobytes
            case .document(let format):
                documentFormat = format
            case .audio(let format):
                audioFormat = format
            case .video(let format):
                videoFormat = format
            case .passthrough:
                break
            }
        }
    }

    /// True when the plan already matches the standing defaults — the button says so rather than
    /// offering to save something that would change nothing.
    func matches(_ plan: Blueprint) -> Bool {
        let store = UserDefaults(suiteName: Self.probeSuite) ?? .standard
        defer { Self.discardSuite(Self.probeSuite, from: store) }
        let probe = Defaults(store: store)
        probe.copySettings(from: self)
        probe.adopt(plan)
        return probe.planDefaults == planDefaults && probe.scrubLevel == scrubLevel
    }

    /// One fixed name rather than a fresh UUID: this runs on every plan change, and a suite is a
    /// file on disk. It is torn down after each use anyway.
    private static let probeSuite = "trinket.probe"

    /// Removes a throwaway defaults suite **completely**.
    ///
    /// `removePersistentDomain` alone is not enough: it empties the plist but leaves a 42-byte
    /// `{}` file behind, so a run that makes a suite per check still litters
    /// `~/Library/Preferences`. 366 of them had accumulated before anybody looked in there. The
    /// values were gone from all of them — this is tidiness, not a data leak — but a check with a
    /// permanent side effect on the user's home folder is still a check that is doing damage.
    static func discardSuite(_ name: String, from store: UserDefaults) {
        store.removePersistentDomain(forName: name)
        let plist = URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Preferences/\(name).plist")
        try? FileManager.default.removeItem(at: plist)
    }

    private func copySettings(from other: Defaults) {
        imageFormat = other.imageFormat
        quality = other.quality
        longestEdge = other.longestEdge
        targetKilobytes = other.targetKilobytes
        documentFormat = other.documentFormat
        audioFormat = other.audioFormat
        videoFormat = other.videoFormat
        scrubLevel = other.scrubLevel
    }

    static func selfCheck() {
        let suite = "trinket.check.defaults"
        let store = UserDefaults(suiteName: suite)!
        // A suite is a real plist in ~/Library/Preferences and it outlives the process. Without
        // this, every run of `--self-check` left one behind for ever — and `package-app.sh` runs
        // one on every build. Found at 366 files.
        defer { Self.discardSuite(suite, from: store) }
        let defaults = Defaults(store: store)

        // A fresh install starts on the shipped factory settings, not on some other value.
        assert(defaults.imageFormat == Factory.imageFormat)
        assert(defaults.scrubLevel == Factory.scrubLevel)
        assert(defaults.targetKilobytes == Factory.targetKilobytes)
        assert(defaults.outputLocation == Factory.outputLocation)
        assert(defaults.windowFrost == Factory.windowFrost)
        // A stored `false` must survive: reading it with `?? true` would flip it back on at every
        // launch, which is the classic "my setting keeps resetting" bug.
        defaults.floatingResults = false
        assert(!Defaults(store: store).floatingResults, "a stored false was read back as true")

        // The original file is never touched by default — the one setting that destroys data.
        assert(Factory.originalHandling == .keep)

        // Adopting a plan writes its settings through to the standing defaults.
        var plan = Blueprint(scrub: .locationOnly)
        plan.lanes = [Lane(kind: .image, itemCount: 1, unpack: nil,
                           shrink: ShrinkStage(kind: .image, target: .image(.png),
                                               quality: 0.42, longestEdge: 800, targetKilobytes: 99))]
        defaults.adopt(plan)
        assert(defaults.imageFormat == .png && defaults.quality == 0.42)
        assert(defaults.longestEdge == 800 && defaults.targetKilobytes == 99)
        assert(defaults.scrubLevel == .locationOnly)
        assert(defaults.matches(plan), "a plan just adopted must count as matching")

        defaults.resetToFactory()
        assert(defaults.imageFormat == Factory.imageFormat && defaults.quality == Factory.quality)
    }

    private enum Key {
        static let hasLaunchedBefore = "hasLaunchedBefore"
        static let imageFormat = "imageFormat"
        static let quality = "quality"
        static let longestEdge = "longestEdge"
        static let targetKilobytes = "targetKilobytes"
        static let documentFormat = "documentFormat"
        static let audioFormat = "audioFormat"
        static let videoFormat = "videoFormat"
        static let scrubLevel = "scrubLevel"
        static let originalHandling = "originalHandling"
        static let outputLocation = "outputLocation"
        static let renaming = "renaming"
        static let viewMode = "viewMode"
        static let outputFolder = "outputFolder"
        static let windowFrost = "windowFrost"
        static let floatingResults = "floatingResults"
        static let showLogSidebar = "showLogSidebar"
        static let planSidebarWidth = "planSidebarWidth"
        static let logSidebarWidth = "logSidebarWidth"

        static let all = [hasLaunchedBefore, imageFormat, quality, longestEdge, targetKilobytes,
                          documentFormat, audioFormat, videoFormat, scrubLevel, originalHandling,
                          outputFolder, outputLocation, renaming, viewMode, windowFrost, floatingResults, showLogSidebar,
                          planSidebarWidth, logSidebarWidth]
    }
}

/// What the planner starts from. A plain value so `Planner` stays pure and testable without an app.
struct PlanDefaults: Equatable {
    var imageFormat: ImageFormat = .keep
    var quality: Double = 0.75
    var longestEdge: Int = 1024
    var targetKilobytes: Int = 0
    var documentFormat: DocumentFormat = .keep
    var audioFormat: AudioFormat = .keep
    var videoFormat: VideoFormat = .keep
    var scrubLevel: ScrubLevel = .shareSafe
}

/// Where results are written.
enum OutputLocation: String, Codable, CaseIterable, Identifiable {
    /// One folder for everything, wherever the user pointed it.
    case folder
    /// Next to the file it came from — the results land in the same folder as the original.
    case besideOriginal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .folder:         return "A folder"
        case .besideOriginal: return "Beside the original"
        }
    }

    var note: String {
        switch self {
        case .folder:         return "Everything lands in one place."
        case .besideOriginal: return "Each result is written into the same folder as the file it came from."
        }
    }
}

/// What happens to the file the user dropped, once a smaller one exists beside it.
enum OriginalHandling: String, Codable, CaseIterable, Identifiable {
    case keep, trash, replace
    var id: String { rawValue }

    var title: String {
        switch self {
        case .keep: return "Keep"
        case .trash: return "Move to Trash"
        case .replace: return "Replace"
        }
    }
}

// MARK: - Plumbing

private extension UserDefaults {
    func contains(_ key: String) -> Bool { object(forKey: key) != nil }

    func decode<T: RawRepresentable>(_ key: String) -> T? where T.RawValue == String {
        guard let raw = string(forKey: key) else { return nil }
        return T(rawValue: raw)
    }

    func encode<T: RawRepresentable>(_ value: T, _ key: String) where T.RawValue == String {
        set(value.rawValue, forKey: key)
    }

    /// For values with more than one field. JSON rather than a key each, so adding a field to
    /// `Renaming` does not mean adding a preference key and remembering to migrate it.
    func decodeJSON<T: Decodable>(_ key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func encodeJSON<T: Encodable>(_ value: T, _ key: String) {
        set(try? JSONEncoder().encode(value), forKey: key)
    }
}

extension Double {
    func clamped(_ low: Double, _ high: Double) -> Double { Swift.min(Swift.max(self, low), high) }
}
