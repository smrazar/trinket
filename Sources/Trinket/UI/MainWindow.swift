import SwiftUI
import UniformTypeIdentifiers
import QuickLook

/// The window: **plan sidebar (left) · file list (centre) · log panel (right)**, symmetrical,
/// each side toggled from the toolbar.
///
/// Responsive at three widths. At the 720pt minimum **neither sidebar fits**, so the plan
/// survives as a compact breadcrumb strip above the list — guidance is never lost, the list gets
/// the full width, and the filename finally reads.
struct MainWindow: View {
    @EnvironmentObject private var defaults: Defaults
    @StateObject private var batch = Batch()
    @StateObject private var runner = Runner()
    @ObservedObject private var logbook = Logbook.shared
    @ObservedObject private var inbox = FileInbox.shared

    @State private var plan = Blueprint()
    @State private var estimate = Estimate()
    @State private var facts: [FileFact] = []
    @State private var isAnalysing = false
    @State private var isTargeted = false
    @State private var selection: Set<UUID> = []
    @State private var unpackedRoots: [URL] = []

    @State private var quickLookURL: URL?
    @State private var comparing: Item?
    @State private var inspecting: Item?
    @State private var showScrubReport = false
    @State private var showRenaming = false

    var body: some View {
        GeometryReader { geometry in
            let layout = Layout(width: geometry.size.width,
                                logRequested: defaults.showLogSidebar,
                                hasPlan: !plan.isEmpty)
            VStack(spacing: 0) {
                Toolbar(layout: layout,
                        hasSelection: !selection.isEmpty,
                        hasFiles: !batch.isEmpty,
                        isRunning: runner.isRunning,
                        canRun: !plan.isEmpty && !batch.isEmpty && !runner.isRunning,
                        viewMode: $defaults.viewMode,
                        showLog: $defaults.showLogSidebar,
                        onAdd: chooseFiles,
                        onRun: run,
                        onStop: runner.cancel,
                        onClear: newBatch,
                        onSelectAll: { selection = Set(batch.items.map(\.id)) },
                        onQuickLook: { quickLookSelection() },
                        onCompare: { comparing = firstSelected },
                        onInspect: { inspecting = firstSelected },
                        onReveal: { revealSelection() })
                Hairline()
                content(layout)
            }
            .background(Tokens.Ink.window.color)
        }
        .frame(minWidth: Tokens.Width.minimum, minHeight: Tokens.Width.minimumHeight)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted, perform: accept)
        .onAppear { drainInbox() }
        .onChange(of: inbox.pending) { _, _ in drainInbox() }
        .quickLookPreview($quickLookURL)
        .sheet(item: $comparing) { item in
            CompareSheet(item: item) { comparing = nil }
        }
        .sheet(item: $inspecting) { item in
            MetadataSheet(item: item, level: plan.scrub) { inspecting = nil }
        }
        .sheet(isPresented: $showScrubReport) {
            ScrubReportSheet(report: batch.scrubReport, level: plan.scrub) { showScrubReport = false }
        }
        .sheet(isPresented: $showRenaming) {
            // Given the real files, so the preview table shows what *these* names become rather
            // than an example nobody dropped.
            RenamingSheet(renaming: $defaults.renaming,
                          files: batch.items.map {
                              ($0.url.deletingPathExtension().lastPathComponent,
                               $0.url.pathExtension, $0.kind)
                          }) { showRenaming = false }
        }
        .onChange(of: plan) { _, updated in
            estimate = Estimate.of(facts, under: updated)
            applyEstimateToRows()
        }
        // The card exists because the main window is usually behind something by the time a long
        // batch ends. Showing it only on the transition *into* finished, so a redraw cannot
        // re-show it.
        .onChange(of: runner.phase) { previous, current in
            guard current == .finished, previous != .finished, defaults.floatingResults else { return }
            showFloatingResult()
        }
        // Menu commands reach the window through notifications rather than shared state: the
        // menu is built once by the App, the window can come and go, and a stale binding into a
        // dead window is exactly how a menu item starts doing nothing.
        .onReceive(NotificationCenter.default.publisher(for: .trinketAddFiles)) { _ in chooseFiles() }
        .onReceive(NotificationCenter.default.publisher(for: .trinketNewBatch)) { _ in newBatch() }
        .onReceive(NotificationCenter.default.publisher(for: .trinketRun)) { _ in
            guard !plan.isEmpty, !batch.isEmpty, !runner.isRunning else { return }
            run()
        }
        .onReceive(NotificationCenter.default.publisher(for: .trinketSelectAll)) { _ in
            selection = Set(batch.items.map(\.id))
        }
        .onDisappear { cleanUpScratch() }
    }

    // MARK: - Layout

    /// Which panels actually fit. A user can ask for both sidebars, but at 720pt the answer is
    /// no — and the plan becomes a breadcrumb rather than disappearing.
    struct Layout {
        let width: CGFloat
        let showsPlanSidebar: Bool
        let showsLogSidebar: Bool
        let showsBreadcrumb: Bool

        init(width: CGFloat, logRequested: Bool, hasPlan: Bool) {
            self.width = width
            // **The plan sidebar is always shown when it fits.** Every control the app has lives
            // in it — formats, quality, resize, target size, scrub level — so hiding it leaves a
            // window that can only do exactly what it was already going to do. It was a toggle;
            // that was wrong. With nothing dropped it shows the settings the next drop will use,
            // so the app can be set up before a file arrives rather than only after.
            let roomForOne = width >= Tokens.Width.comfortable
            let roomForBoth = width >= Tokens.Width.wide
            showsPlanSidebar = roomForOne
            showsLogSidebar = logRequested && roomForBoth
            // Below that width it survives as the breadcrumb strip, but only once there is a real
            // plan — a breadcrumb of defaults above an empty drop target is noise.
            showsBreadcrumb = hasPlan && !showsPlanSidebar
        }
    }

    @ViewBuilder
    private func content(_ layout: Layout) -> some View {
        HStack(spacing: 0) {
            if layout.showsPlanSidebar {
                planSidebar
                    .frame(width: defaults.planSidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                ResizableDivider(width: $defaults.planSidebarWidth,
                                 side: .leading,
                                 range: Tokens.Width.planRange,
                                 defaultWidth: Tokens.Width.planSidebar)
            }

            VStack(spacing: 0) {
                if layout.showsBreadcrumb, !batch.isEmpty {
                    BreadcrumbStrip(plan: plan)
                    Hairline()
                }
                centre
            }
            // The centre takes whatever the sidebars leave, and never less than a readable
            // filename's worth — the sidebars' own maximums are what stop it being squeezed.
            .frame(maxWidth: .infinity)
            .layoutPriority(1)

            if layout.showsLogSidebar {
                ResizableDivider(width: $defaults.logSidebarWidth,
                                 side: .trailing,
                                 range: Tokens.Width.logRange,
                                 defaultWidth: Tokens.Width.logSidebar)
                LogPane(logbook: logbook) { defaults.showLogSidebar = false }
                    .frame(width: defaults.logSidebarWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Tokens.Motion.stage, value: layout.showsPlanSidebar)
        .animation(Tokens.Motion.stage, value: layout.showsLogSidebar)
    }

    @ViewBuilder
    private var centre: some View {
        if isAnalysing {
            AnalysingState(count: batch.items.isEmpty ? 1 : batch.items.count)
        } else if batch.isEmpty {
            EmptyState(isTargeted: isTargeted, onChoose: chooseFiles)
        } else {
            FileList(batch: batch,
                     phase: runner.phase,
                     plan: plan,
                     estimate: estimate,
                     failureNote: runner.failureNote,
                     selection: $selection,
                     mode: defaults.viewMode,
                     onQuickLook: { quickLookURL = $0.outputURL ?? $0.url },
                     onCompare: { comparing = $0 },
                     onReveal: { NSWorkspace.shared.activateFileViewerSelecting([$0.outputURL ?? $0.url]) },
                     onInspect: { inspecting = $0 },
                     onRemove: remove)
        }
    }

    /// With nothing dropped there is no plan to show, so the sidebar shows the **settings the
    /// next drop will use** — the same controls, bound to the standing defaults. Editing them
    /// there writes straight through, which is what makes the sidebar usable before a file
    /// arrives instead of only after one.
    private var sidebarPlan: Binding<Blueprint> {
        guard plan.isEmpty else { return $plan }
        return Binding(
            get: { Planner.preview(defaults.planDefaults, hasFFmpeg: Shell.hasFFmpeg) },
            set: { edited in defaults.adopt(edited) }
        )
    }

    private var planSidebar: some View {
        PlanSidebar(plan: sidebarPlan,
                    phase: runner.phase,
                    estimate: estimate,
                    report: batch.scrubReport,
                    bundleName: runner.bundleURL?.lastPathComponent,
                    onRun: run,
                    onPause: runner.pause,
                    onResume: runner.resume,
                    onCancel: runner.cancel,
                    onReveal: revealResults,
                    onNewBatch: newBatch,
                    onInspectMetadata: { showScrubReport = true },
                    onEditRenaming: { showRenaming = true },
                    renaming: $defaults.renaming)
    }

    // MARK: - Dropping

    private func accept(_ providers: [NSItemProvider]) -> Bool {
        guard runner.phase != .running, runner.phase != .paused else { return false }
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                   let resolved = URL(dataRepresentation: url, relativeTo: nil) {
                    urls.append(resolved)
                }
            }
            guard !urls.isEmpty else { return }
            await load(urls)
        }
        return true
    }

    /// Takes whatever *Open With* or `open -a` left waiting. Left in the inbox while a batch is
    /// running rather than thrown away — the run finishes, and the files are still there.
    private func drainInbox() {
        guard !inbox.pending.isEmpty,
              runner.phase != .running, runner.phase != .paused else { return }
        let urls = inbox.drain()
        Task { await load(urls) }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        Task { await load(panel.urls) }
    }

    private func load(_ urls: [URL]) async {
        cleanUpScratch()
        runner.reset()
        selection = []
        isAnalysing = true
        logInfo("analyse \(urls.count) \(urls.count == 1 ? "item" : "items")")

        // The analysis reads every file's header and metadata — never on the main thread.
        let result = await Task.detached(priority: .userInitiated) {
            Analyser.analyse(urls, unpackArchives: true)
        }.value

        batch.clear()
        batch.items = result.items.map { seed in
            let item = Item(url: seed.url, container: seed.container)
            item.findings = seed.findings
            return item
        }
        batch.droppedContainer = result.droppedContainer
        batch.scrubReport = result.report
        unpackedRoots = result.unpackedRoots
        facts = result.facts

        var input = PlanInput(files: result.facts, hasFFmpeg: Shell.hasFFmpeg)
        input.droppedArchive = result.droppedContainer != nil
        input.archiveEntryCount = result.archiveEntryCount
        input.defaults = defaults.planDefaults
        plan = Planner.propose(input)
        estimate = Estimate.of(result.facts, under: plan)
        applyEstimateToRows()

        logInfo("plan: \(plan.breadcrumb.joined(separator: " → "))")
        if estimate.isWorthShowing {
            logInfo("estimate: \(Bytes.pair(from: estimate.before, to: estimate.after)) (−\(estimate.percent)%)")
        }
        if result.alreadyProduced > 0 {
            let n = result.alreadyProduced
            plan.caveats.append(.init(
                text: "\(n) \(n == 1 ? "file was" : "files were") left out — trinket produced "
                    + "\(n == 1 ? "it" : "them") already. Results land beside your originals, so a "
                    + "folder dropped twice would otherwise re-shrink its own output."))
        }
        for caveat in plan.caveats where caveat.isNotYet { logWarn(caveat.text) }
        logInfo("ready — waiting on Run")
        isAnalysing = false
    }

    /// The pre-run size pair on each row comes from the same predictor as the sidebar total, so
    /// the rows and the headline can never disagree.
    private func applyEstimateToRows() {
        for (item, fact) in zip(batch.items, facts) {
            item.estimatedSize = Estimate.predict(fact, under: plan)
        }
    }

    // MARK: - Actions

    private func run() {
        guard !plan.isEmpty else { return }
        selection = []
        runner.run(batch: batch, plan: plan, defaults: defaults)
    }

    private func newBatch() {
        FloatingResultController.shared.dismiss()
        cleanUpScratch()
        runner.reset()
        batch.clear()
        plan = Blueprint()
        estimate = Estimate()
        facts = []
        selection = []
    }

    private func remove(_ item: Item) {
        batch.items.removeAll { $0.id == item.id }
        selection.remove(item.id)
        facts = []
        // The plan is derived from what is in the batch, so removing a file re-proposes it.
        Task { await reanalyse() }
    }

    private func reanalyse() async {
        let urls = batch.items.map(\.url)
        guard !urls.isEmpty else { newBatch(); return }
        await load(urls)
    }

    private var firstSelected: Item? {
        batch.items.first { selection.contains($0.id) }
    }

    private func quickLookSelection() {
        guard let item = firstSelected else { return }
        quickLookURL = item.outputURL ?? item.url
    }

    private func revealSelection() {
        let urls = batch.items.filter { selection.contains($0.id) }.map { $0.outputURL ?? $0.url }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func revealResults() {
        if let bundle = runner.bundleURL {
            NSWorkspace.shared.activateFileViewerSelecting([bundle])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([defaults.outputFolder])
        }
    }

    private func showFloatingResult() {
        // Converted files only, for the same reason the banner uses them: one untouched archive
        // in the drop otherwise swallows the whole figure.
        let saved = max(0, batch.convertedOriginal - batch.convertedShown)
        let done = batch.convertedItems
        let failed = batch.items.filter(\.state.isFailure).count
        let untouched = batch.items.filter {
            if case .passedThrough = $0.state { return true }
            return false
        }.count

        FloatingResultController.shared.show(
            .init(saved: saved,
                  percent: Bytes.savings(from: batch.convertedOriginal, to: batch.convertedShown) ?? 0,
                  fileCount: done.count,
                  failedCount: failed,
                  untouchedCount: untouched,
                  reveal: runner.bundleURL ?? done.first?.outputURL),
            onReveal: revealResults)
    }

    /// The unpacked archive lives in a temporary folder that nothing else will clear.
    private func cleanUpScratch() {
        for root in unpackedRoots { try? FileManager.default.removeItem(at: root) }
        unpackedRoots = []
    }
}

// MARK: - Toolbar

/// Left→right: sidebar toggle · title · then, right-aligned, the quick actions **on the
/// selection** — Quick Look, Compare, Show in Finder — a divider, the log toggle, and Settings.
/// Nothing joins this bar without something else leaving it.
struct Toolbar: View {
    let layout: MainWindow.Layout
    let hasSelection: Bool
    let hasFiles: Bool
    let isRunning: Bool
    let canRun: Bool
    @Binding var viewMode: ViewMode
    @Binding var showLog: Bool

    let onAdd: () -> Void
    let onRun: () -> Void
    let onStop: () -> Void
    let onClear: () -> Void
    let onSelectAll: () -> Void
    let onQuickLook: () -> Void
    let onCompare: () -> Void
    let onInspect: () -> Void
    let onReveal: () -> Void

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: Tokens.Space.sm) {
            TrinketMark(size: 18)
            Text("trinket")
                .font(Tokens.Face.bodyStrong)
                .foregroundStyle(Tokens.Ink.ink.color)

            divider

            // The batch itself: add files, run them, stop, start over. These were only reachable
            // from the sidebar or a menu; they are the four things done most often.
            ToolbarButton(icon: Symbols.add, help: "Add files…", action: onAdd)
            if isRunning {
                ToolbarButton(icon: Symbols.stop, help: "Stop", action: onStop)
            } else {
                ToolbarButton(icon: Symbols.run, help: "Run the plan",
                              isEnabled: canRun, action: onRun)
            }
            ToolbarButton(icon: Symbols.clearList, help: "Clear the list",
                          isEnabled: hasFiles && !isRunning, action: onClear)

            Spacer()

            // On the selection.
            ToolbarButton(icon: Symbols.selectAll, help: "Select all",
                          isEnabled: hasFiles, action: onSelectAll)
            ToolbarButton(icon: Symbols.quickLook, help: "Quick Look",
                          isEnabled: hasSelection, action: onQuickLook)
            ToolbarButton(icon: Symbols.compare, help: "Compare before / after",
                          isEnabled: hasSelection, action: onCompare)
            ToolbarButton(icon: Symbols.scrub, help: "Inspect metadata",
                          isEnabled: hasSelection, action: onInspect)
            ToolbarButton(icon: Symbols.reveal, help: "Show in Finder",
                          isEnabled: hasSelection, action: onReveal)

            divider

            // How the middle panel draws them.
            ForEach(ViewMode.allCases) { option in
                ToolbarButton(icon: option.icon,
                              help: option.title,
                              isSelected: viewMode == option) {
                    withAnimation(Tokens.Motion.quick) { viewMode = option }
                }
            }

            divider

            ToolbarButton(icon: Symbols.log,
                          help: showLog ? "Hide the log" : "Show the log",
                          isSelected: layout.showsLogSidebar,
                          isEnabled: layout.width >= Tokens.Width.wide) {
                showLog.toggle()
            }
            ToolbarButton(icon: Symbols.settings, help: "Settings") {
                openWindow(id: "settings")
            }
        }
        .padding(.horizontal, Tokens.Space.lg)
        .padding(.vertical, Tokens.Space.sm)
        .frame(height: 44)
        .background(Tokens.Ink.sidebar.color)
    }

    private var divider: some View {
        Rectangle()
            .fill(Tokens.Ink.line.color)
            .frame(width: 1, height: 18)
            .padding(.horizontal, Tokens.Space.xs)
    }
}

// MARK: - Breadcrumb

/// At the minimum width the plan collapses to this strip, so guidance survives without a sidebar:
/// `Unpack › Reduce · 75% · 1024px › Bundle · zip`.
struct BreadcrumbStrip: View {
    let plan: Blueprint

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Tokens.Space.sm) {
                GroupHeading(text: "Plan")
                    .padding(.trailing, Tokens.Space.xs)

                ForEach(Array(plan.breadcrumb.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: Symbols.disclosure)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Tokens.Ink.inkTertiary.color)
                    }
                    Text(crumb)
                        .font(Tokens.Face.body)
                        .foregroundStyle(Tokens.Ink.ink.color)
                        .padding(.horizontal, Tokens.Space.md)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(Tokens.Ink.window.color)
                                .overlay(Capsule().strokeBorder(Tokens.Ink.line.color, lineWidth: 1))
                        )
                        .fixedSize()
                }

                Spacer(minLength: Tokens.Space.md)

                Label("Scrub: \(plan.scrub.shortTitle)", systemImage: Symbols.scrub)
                    .font(Tokens.Face.body)
                    .foregroundStyle(Tokens.Ink.inkSecondary.color)
                    .fixedSize()
            }
            .padding(.horizontal, Tokens.Space.xl)
            .padding(.vertical, Tokens.Space.md)
        }
        .background(Tokens.Ink.sidebar.color)
    }
}
