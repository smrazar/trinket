import Foundation
import SwiftUI

/// One line in the log panel. The panel is a right sidebar, flat, monospace — see LogPane.
struct LogLine: Identifiable, Equatable {
    enum Level: Equatable {
        case info
        /// Amber. Skipped, not-yet-supported, passed through unchanged.
        case warn
        /// Red. Failed.
        case fail
    }

    let id = UUID()
    let at: Date
    let level: Level
    let text: String

    var stamp: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: at)
    }
}

/// The app's log. Lines are kept in memory for the panel and appended to a file on disk so a
/// crash still leaves evidence. Observable so the panel redraws; writes are serialised off-main.
@MainActor
final class Logbook: ObservableObject {
    static let shared = Logbook()

    /// Beyond this the panel stops being a log and starts being a memory leak.
    private static let ceiling = 5_000

    @Published private(set) var lines: [LogLine] = []

    let fileURL: URL
    private let writeQueue = DispatchQueue(label: "trinket.logbook", qos: .utility)

    /// `~/Library/Logs/trinket/session.log`, as the mockup's footer promises.
    var displayPath: String {
        fileURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/trinket", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appending(path: "session.log")
    }

    func info(_ text: String) { append(.info, text) }
    func warn(_ text: String) { append(.warn, text) }
    func fail(_ text: String) { append(.fail, text) }

    func clear() {
        lines = []
        writeQueue.async { [fileURL] in try? Data().write(to: fileURL) }
    }

    func copyAll() {
        let text = lines.map { "\($0.stamp)  \($0.text)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func append(_ level: LogLine.Level, _ text: String) {
        let line = LogLine(at: Date(), level: level, text: text)
        lines.append(line)
        if lines.count > Self.ceiling {
            lines.removeFirst(lines.count - Self.ceiling)
        }
        let encoded = "\(line.stamp) \(prefix(level))\(text)\n"
        writeQueue.async { [fileURL] in
            guard let data = encoded.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    private func prefix(_ level: LogLine.Level) -> String {
        switch level {
        case .info: return ""
        case .warn: return "warn "
        case .fail: return "fail "
        }
    }
}

extension Notification.Name {
    static let trinketAddFiles = Notification.Name("trinket.addFiles")
    static let trinketNewBatch = Notification.Name("trinket.newBatch")
    static let trinketRun = Notification.Name("trinket.run")
    static let trinketSelectAll = Notification.Name("trinket.selectAll")
}

/// Free function so engines can log without reaching for the main actor at every call site.
func logInfo(_ text: String) { Task { @MainActor in Logbook.shared.info(text) } }
func logWarn(_ text: String) { Task { @MainActor in Logbook.shared.warn(text) } }
func logFail(_ text: String) { Task { @MainActor in Logbook.shared.fail(text) } }
