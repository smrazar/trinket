import SwiftUI
import AppKit

@main
struct TrinketApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var defaults = Defaults.shared
    @Environment(\.openWindow) private var openWindow

    init() {
        // `trinket --self-check` runs the whole suite and exits, so CI and a packaged build can
        // both be verified without a window ever appearing.
        if CommandLine.arguments.contains("--self-check") {
            Self.runSelfCheckAndExit()
        }
        #if DEBUG
        SelfChecks.runAll()
        #endif
    }

    /// The pipeline check is `@MainActor`, so blocking the main thread to wait for it deadlocks —
    /// the work it is waiting on can only run on the thread it just parked. Hand the whole run to
    /// the main actor and pump the run loop instead; `exit` inside the task ends the process.
    private static func runSelfCheckAndExit() -> Never {
        Task { @MainActor in
            SelfChecks.runAll()
            await PipelineCheck.run()
            print("self-checks passed")
            exit(0)
        }
        RunLoop.main.run()
        fatalError("the run loop returned before the self-check finished")
    }

    var body: some Scene {
        Window("trinket", id: "main") {
            RootView()
                .environmentObject(defaults)
        }
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1180, height: 860)
        .commands { commands }

        Window("Settings", id: "settings") {
            SettingsWindow().environmentObject(defaults)
        }
        .windowResizability(.contentSize)

        Window("About trinket", id: "about") {
            AboutWindow()
        }
        .windowResizability(.contentSize)
    }

    @CommandsBuilder
    private var commands: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About trinket") { openWindow(id: "about") }
        }
        // Settings is a `Window` rather than SwiftUI's `Settings` scene, so it does not get
        // ⌘, for free — and every Mac user reaches for ⌘, first. Without this the only way in
        // is the toolbar gear.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openWindow(id: "settings") }
                .keyboardShortcut(",", modifiers: .command)
        }
        // The verbs a Mac user reaches for without thinking. Everything here is also a button;
        // these exist so the app can be driven without going to the toolbar for each batch.
        CommandGroup(replacing: .newItem) {
            Button("Add Files…") { NotificationCenter.default.post(name: .trinketAddFiles, object: nil) }
                .keyboardShortcut("o", modifiers: .command)
            Button("New Batch") { NotificationCenter.default.post(name: .trinketNewBatch, object: nil) }
                .keyboardShortcut("n", modifiers: .command)
            Divider()
            Button("Run Plan") { NotificationCenter.default.post(name: .trinketRun, object: nil) }
                .keyboardShortcut("r", modifiers: .command)
        }
        CommandGroup(after: .pasteboard) {
            Button("Select All Files") { NotificationCenter.default.post(name: .trinketSelectAll, object: nil) }
                .keyboardShortcut("a", modifiers: .command)
        }
        CommandGroup(after: .toolbar) {
            // No "Show Plan": the plan sidebar is not hideable any more, and a menu item that
            // toggles a preference nothing reads is worse than no menu item.
            Button("Show Log") { defaults.showLogSidebar.toggle() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}

/// Wraps the main window so first launch can show the welcome screen before anything else.
struct RootView: View {
    @EnvironmentObject private var defaults: Defaults

    var body: some View {
        Group {
            if defaults.hasLaunchedBefore {
                MainWindow()
            } else {
                WelcomeWindow {
                    withAnimation(Tokens.Motion.stage) { defaults.hasLaunchedBefore = true }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.Ink.window.color)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        logInfo("trinket \(Bundle.version) (\(Bundle.build)) — ready")
        if !Shell.hasFFmpeg {
            logWarn("ffmpeg is not in this build — video passes through unchanged")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Finder's *Open With*, `open -a trinket …`, and dropping files on the Dock icon all arrive
    /// here.
    ///
    /// `Info.plist` has declared `CFBundleDocumentTypes` since 1.0, so trinket was already listed
    /// in Finder's Open With menu — and choosing it launched the app to an empty window and threw
    /// the files away, because nothing implemented this method. Declaring a document type is a
    /// promise; this is the half that keeps it.
    func application(_ application: NSApplication, open urls: [URL]) {
        logInfo("open \(urls.count) \(urls.count == 1 ? "item" : "items") from outside the app")
        FileInbox.shared.deliver(urls)
    }
}

/// Files handed to trinket from outside it.
///
/// A buffer rather than a bare notification, because a cold launch delivers the URLs *before* any
/// window exists to hear them — the window drains whatever is waiting once it appears.
///
/// **Deliveries are coalesced, and that is the whole difficulty.** macOS does not hand a multi-file
/// open to `application(_:open:)` in one call: selecting fourteen files produced a call with
/// thirteen and a second call with one. Loading a batch per call means each one resets the batch
/// before it, so the last delivery wins and everything else disappears without an error. Measured
/// on the first real test of this path — fourteen files opened, thirteen analysed, the video gone.
@MainActor
final class FileInbox: ObservableObject {
    static let shared = FileInbox()

    /// Published only once a burst of deliveries has settled.
    @Published private(set) var pending: [URL] = []

    /// Long enough to catch the second call of a split delivery, short enough that a single-file
    /// open still feels immediate.
    static let settle = Duration.milliseconds(400)

    private var collecting: [URL] = []
    private var settleTask: Task<Void, Never>?

    func deliver(_ urls: [URL]) {
        collecting.append(contentsOf: urls)
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled, let self, !self.collecting.isEmpty else { return }
            self.pending = self.collecting
            self.collecting = []
        }
    }

    func drain() -> [URL] {
        defer { pending = [] }
        return pending
    }
}
