import SwiftUI

/// The left sidebar **is** the plan: one section per stage, in the order the analyser chose,
/// every decision pre-answered and collapsed to a single line. A connector rail links them so
/// they read as a path rather than a list of settings.
struct PlanSidebar: View {
    @Binding var plan: Blueprint
    let phase: Runner.Phase
    let estimate: Estimate
    let report: ScrubReport
    let bundleName: String?

    let onRun: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void
    let onReveal: () -> Void
    let onNewBatch: () -> Void
    let onInspectMetadata: () -> Void
    let onEditRenaming: () -> Void
    /// Bound rather than copied, so the card reflects an edit made in the sheet immediately.
    let renaming: Binding<Renaming>

    /// Which stage is open. One at a time — the sidebar is a path, and two open cards at 248pt
    /// leaves no room to see the path itself.
    enum Expanded: Hashable { case shrink(Kind), unpack, bundle }
    @State private var expanded: Expanded?

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(plan.lanes) { lane in
                        if plan.isMixed {
                            // A mixed drop names its lanes. A single-kind drop draws no header —
                            // "Photos" above the only stages there are is noise.
                            GroupHeading(text: lane.title)
                                .padding(.horizontal, Tokens.Space.xl)
                                .padding(.top, Tokens.Space.lg)
                                .padding(.bottom, Tokens.Space.sm)
                        }
                        laneStages(lane)
                    }
                    // Every lane converges here, so the Bundle stage is drawn once, after them
                    // all — not inside whichever lane happened to be last.
                    bundleStage
                    scrubCard
                    renameCard
                    caveats
                }
                .padding(.bottom, Tokens.Space.lg)
            }

            Spacer(minLength: 0)
            footer
        }
        // Width comes from the window, which owns the drag. The trailing hairline is the
        // ResizableDivider's job now, so drawing one here would double it.
        .frame(maxWidth: .infinity)
        .background(Tokens.Ink.sidebar.color)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            GroupHeading(text: plan.isPreview ? "Defaults" : "Plan")
            Spacer()
            switch phase {
            case .running:
                Label("Running", systemImage: Symbols.working)
                    .font(Tokens.Face.body)
                    .foregroundStyle(Tokens.Ink.accent.color)
                    .labelStyle(.titleAndIcon)
            case .paused:
                Label("Paused", systemImage: Symbols.paused)
                    .font(Tokens.Face.body)
                    .foregroundStyle(Tokens.Ink.amber.color)
            case .finished:
                Label("Complete", systemImage: Symbols.done)
                    .font(Tokens.Face.body)
                    .foregroundStyle(Tokens.Ink.green.color)
            default:
                Text(plan.isPreview ? "for the next drop" : plan.stepLabel)
                    .font(Tokens.Face.body)
                    .foregroundStyle(Tokens.Ink.inkSecondary.color)
            }
        }
        .padding(.horizontal, Tokens.Space.xl)
        .padding(.vertical, Tokens.Space.lg)
    }

    // MARK: - Stages

    @ViewBuilder
    private func laneStages(_ lane: Lane) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let unpack = lane.unpack {
                StageRow(title: "Unpack",
                         summary: unpack.summary,
                         icon: Symbols.unpack,
                         state: stageState(for: .unpack),
                         isExpandable: isEditable,
                         isExpanded: expanded == .unpack,
                         hasRailBelow: true,
                         onToggle: { toggle(.unpack) })

                if expanded == .unpack {
                    UnpackStageEditor(stage: Binding(
                        get: { unpack },
                        set: { updated in
                            guard let index = plan.lanes.firstIndex(where: { $0.kind == lane.kind })
                            else { return }
                            plan.lanes[index].unpack = updated
                        }
                    ))
                    .padding(.horizontal, Tokens.Space.xl)
                    .padding(.bottom, Tokens.Space.md)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            if let shrink = lane.shrink {
                StageRow(title: shrink.title,
                         summary: shrink.summary,
                         icon: shrink.face == .reduce ? Symbols.reduce : Symbols.convert,
                         state: stageState(for: .shrink),
                         isExpandable: isEditable,
                         isExpanded: expanded == .shrink(lane.kind),
                         hasRailBelow: plan.bundle.enabled || lane.kind != plan.lanes.last?.kind,
                         onToggle: { toggle(.shrink(lane.kind)) })

                if expanded == .shrink(lane.kind) {
                    ShrinkStageEditor(stage: Binding(
                        get: { shrink },
                        set: { updated in plan.updateShrink(for: lane.kind) { $0 = updated } }
                    ))
                    .padding(.horizontal, Tokens.Space.xl)
                    .padding(.bottom, Tokens.Space.md)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    @ViewBuilder
    private var bundleStage: some View {
        if plan.bundle.enabled {
            StageRow(title: "Bundle",
                     summary: bundleName ?? plan.bundle.summary,
                     icon: Symbols.bundle,
                     state: stageState(for: .bundle),
                     isExpandable: isEditable,
                     isExpanded: expanded == .bundle,
                     hasRailBelow: false,
                     onToggle: { toggle(.bundle) })

            if expanded == .bundle {
                BundleStageEditor(stage: $plan.bundle)
                    .padding(.horizontal, Tokens.Space.xl)
                    .padding(.bottom, Tokens.Space.md)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// Stages are only editable before a run — changing the plan half way through it would mean
    /// some files ran under one setting and the rest under another.
    private var isEditable: Bool { plan.isPreview || phase == .ready || phase == .idle }

    private func toggle(_ target: Expanded) {
        withAnimation(Tokens.Motion.stage) {
            expanded = expanded == target ? nil : target
        }
    }

    private enum StagePosition { case unpack, shrink, bundle }

    /// Stages light up as the run passes through them. Before a run they are all pending, which
    /// draws as an outline rather than a tick.
    private func stageState(for position: StagePosition) -> StageRow.State {
        switch phase {
        case .running, .paused:
            switch position {
            case .unpack: return .done
            case .shrink: return .active
            case .bundle: return .pending
            }
        case .finished:
            return .done
        default:
            return position == .shrink ? .current : .pending
        }
    }

    // MARK: - Scrub

    /// Scrub is not a stage — it is a guarantee, shown in the footer area with its four levels
    /// and a way to see what was found before anything is removed.
    private var scrubCard: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.sm) {
            HStack {
                Label(phase == .finished ? "Scrubbed" : "Scrub", systemImage: Symbols.scrub)
                    .font(Tokens.Face.bodyStrong)
                    .foregroundStyle(Tokens.Ink.ink.color)
                Spacer()
                Text(plan.scrub.shortTitle)
                    .font(Tokens.Face.body)
                    .foregroundStyle(Tokens.Ink.inkSecondary.color)
            }

            Text(scrubBlurb)
                .font(Tokens.Face.body)
                .foregroundStyle(Tokens.Ink.inkSecondary.color)
                .fixedSize(horizontal: false, vertical: true)

            if !report.isEmpty {
                Button(action: onInspectMetadata) {
                    Text("See what was found")
                        .font(Tokens.Face.body)
                        .foregroundStyle(Tokens.Ink.accent.color)
                }
                .buttonStyle(.plain)
            }

            if phase == .idle || phase == .ready {
                ScrubLevelPicker(level: $plan.scrub)
                    .padding(.top, Tokens.Space.xs)
            }
        }
        .padding(Tokens.Space.lg)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                .fill(Tokens.Ink.window.color)
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                        .strokeBorder(Tokens.Ink.line.color, lineWidth: 1)
                )
        )
        .padding(.horizontal, Tokens.Space.lg)
        .padding(.top, Tokens.Space.lg)
    }

    private var scrubBlurb: String {
        if phase == .finished {
            return report.summary(at: plan.scrub) ?? "Nothing needed removing."
        }
        if phase == .running || phase == .paused {
            return "Stripping metadata as each file is rewritten."
        }
        return plan.scrub.explanation
    }

    /// Renaming was reachable only from Settings, which made it the one per-run decision living
    /// somewhere else. It sits beside Scrub now — both are guarantees about the *output* rather
    /// than stages in the path.
    @ViewBuilder
    private var renameCard: some View {
        if isEditable {
            VStack(alignment: .leading, spacing: Tokens.Space.sm) {
                HStack {
                    Label("Rename", systemImage: Symbols.rename)
                        .font(Tokens.Face.bodyStrong)
                        .foregroundStyle(Tokens.Ink.ink.color)
                    Spacer()
                    Text(renaming.wrappedValue.isEnabled ? renaming.wrappedValue.mode.title : "Off")
                        .font(Tokens.Face.body)
                        .foregroundStyle(Tokens.Ink.inkSecondary.color)
                }

                if renaming.wrappedValue.isEnabled {
                    Text(renaming.wrappedValue.example())
                        .font(Tokens.Face.mono)
                        .foregroundStyle(Tokens.Ink.accent.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Results keep the name they came in with.")
                        .font(Tokens.Face.body)
                        .foregroundStyle(Tokens.Ink.inkSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: onEditRenaming) {
                    Text(renaming.wrappedValue.isEnabled ? "Change how results are named"
                                                         : "Rename results…")
                        .font(Tokens.Face.body)
                        .foregroundStyle(Tokens.Ink.accent.color)
                }
                .buttonStyle(.plain)
            }
            .padding(Tokens.Space.lg)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                    .fill(Tokens.Ink.window.color)
                    .overlay(
                        RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                            .strokeBorder(Tokens.Ink.line.color, lineWidth: 1)
                    )
            )
            .padding(.horizontal, Tokens.Space.lg)
            .padding(.top, Tokens.Space.md)
        }
    }

    @ViewBuilder
    private var caveats: some View {
        if !plan.caveats.isEmpty, phase != .finished {
            VStack(alignment: .leading, spacing: Tokens.Space.sm) {
                ForEach(plan.caveats) { caveat in
                    HStack(alignment: .top, spacing: Tokens.Space.sm) {
                        Image(systemName: caveat.isNotYet ? Symbols.notYet : "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(caveat.isNotYet ? Tokens.Ink.amber.color : Tokens.Ink.inkTertiary.color)
                        Text(caveat.text)
                            .font(Tokens.Face.body)
                            .foregroundStyle(Tokens.Ink.inkSecondary.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, Tokens.Space.xl)
            .padding(.top, Tokens.Space.lg)
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: Tokens.Space.md) {
            Hairline()

            switch phase {
            case .running, .paused:
                runningFooter
            case .finished:
                finishedFooter
            default:
                readyFooter
            }
        }
        .padding(.bottom, Tokens.Space.lg)
    }

    @ViewBuilder
    private var readyFooter: some View {
        if plan.isPreview {
            // Nothing to run yet. Saying so beats a disabled Run button that looks broken.
            Text("These apply to whatever you drop next. Changes save as you make them.")
                .font(Tokens.Face.body)
                .foregroundStyle(Tokens.Ink.inkTertiary.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Tokens.Space.lg)
        } else {
            runFooter
        }
    }

    private var runFooter: some View {
        VStack(spacing: Tokens.Space.sm) {
            if estimate.isWorthShowing {
                // One wrapping line rather than an HStack — at 248pt "Est. 1.2 GB smaller · 47%"
                // has nowhere to go and an HStack cannot break between its children.
                (Text("Est. ").foregroundColor(Tokens.Ink.inkSecondary.color)
                    + Text(estimate.headline).foregroundColor(Tokens.Ink.accent.color))
                    .font(Tokens.Face.bodyStrong)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            PrimaryButton(title: "Run plan", icon: Symbols.run,
                          isEnabled: !plan.isEmpty, action: onRun)
            SaveAsDefaultsButton(plan: plan)
        }
        .padding(.horizontal, Tokens.Space.lg)
    }

    private var runningFooter: some View {
        VStack(spacing: Tokens.Space.md) {
            HStack(spacing: Tokens.Space.sm) {
                if phase == .paused {
                    SecondaryButton(title: "Resume", icon: Symbols.run, action: onResume)
                } else {
                    SecondaryButton(title: "Pause", icon: Symbols.pause, action: onPause)
                }
                SecondaryButton(title: "Stop", icon: Symbols.stop,
                                isDestructive: true, fillsWidth: false, action: onCancel)
            }
        }
        .padding(.horizontal, Tokens.Space.lg)
    }

    private var finishedFooter: some View {
        VStack(spacing: Tokens.Space.sm) {
            PrimaryButton(title: "Show in Finder", icon: Symbols.reveal, action: onReveal)
            SecondaryButton(title: "New batch", action: onNewBatch)
        }
        .padding(.horizontal, Tokens.Space.lg)
    }
}

// MARK: - Stage row

/// One stage: collapsed to a single line stating its decision, expandable to change it.
struct StageRow: View {
    enum State { case pending, current, active, done }

    let title: String
    let summary: String
    let icon: String
    let state: State
    let isExpandable: Bool
    let isExpanded: Bool
    let hasRailBelow: Bool
    let onToggle: () -> Void

    @SwiftUI.State private var isHovering = false

    var body: some View {
        Button(action: { if isExpandable { onToggle() } }) {
            HStack(alignment: .top, spacing: Tokens.Space.md) {
                rail
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Tokens.Face.heading)
                        .foregroundStyle(Tokens.Ink.ink.color)
                    Text(summary)
                        .font(Tokens.Face.body)
                        .foregroundStyle(summaryColour)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: Tokens.Space.sm)
                if isExpandable {
                    Image(systemName: Symbols.disclosure)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Tokens.Ink.inkTertiary.color)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, Tokens.Space.xl)
            .padding(.vertical, Tokens.Space.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isExpandable)
        .background(isHovering && isExpandable ? Tokens.Ink.sidebarSunken.color : .clear)
        .onHover { isHovering = $0 }
    }

    /// The dot, plus the connector line to the next stage — this is what makes the sidebar read
    /// as a path rather than a list of unrelated settings.
    private var rail: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                    .fill(dotFill)
                    .frame(width: 22, height: 22)
                    .overlay(
                        RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                            .strokeBorder(dotBorder, lineWidth: 1)
                    )
                Image(systemName: state == .done ? "checkmark" : icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(dotInk)
            }
            if hasRailBelow {
                Rectangle()
                    .fill(Tokens.Ink.line.color)
                    .frame(width: 1)
                    .frame(minHeight: 18)
            }
        }
        .frame(width: 22)
    }

    private var dotFill: Color {
        switch state {
        case .active: return Tokens.Ink.accent.color
        case .done:   return Tokens.Ink.green + 0.14
        default:      return Tokens.Ink.window.color
        }
    }

    private var dotBorder: Color {
        switch state {
        case .active: return .clear
        case .done:   return Tokens.Ink.green + 0.35
        default:      return Tokens.Ink.line.color
        }
    }

    private var dotInk: Color {
        switch state {
        case .active: return .white
        case .done:   return Tokens.Ink.green.color
        default:      return Tokens.Ink.inkTertiary.color
        }
    }

    private var summaryColour: Color {
        state == .active ? Tokens.Ink.accent.color : Tokens.Ink.inkSecondary.color
    }
}

// MARK: - Stage editor

/// The expanded stage. Reduce owns quality / longest edge / target size; Convert gains a format
/// picker with the same reduction controls nested inside it.
struct ShrinkStageEditor: View {
    @Binding var stage: ShrinkStage

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.md) {
            if stage.kind == .image {
                FieldLabel("Convert to")
                PaletteMenu(options: ImageFormat.writable.map { ($0, $0.title, $0 == .keep ? nil : $0.note) },
                            selection: imageFormat)
            } else if stage.kind == .audio {
                FieldLabel("Convert to")
                PaletteMenu(options: AudioFormat.available.map { ($0, $0.title, $0 == .keep ? nil : $0.note) },
                            selection: audioFormat)
            } else if stage.kind == .video, !VideoFormat.available.isEmpty {
                FieldLabel("Convert to")
                PaletteMenu(options: VideoFormat.available.map { ($0, $0.title, $0 == .keep ? nil : $0.note) },
                            selection: videoFormat)
            }

            // A lossless target has no quality to set, so the slider is absent rather than
            // present and inert.
            if stage.target.hasQuality {
                FieldLabel("Quality")
                HStack(spacing: Tokens.Space.md) {
                    PaletteSlider(value: $stage.quality, range: 0.1...1.0)
                    Text("\(Int((stage.quality * 100).rounded()))%")
                        .font(Tokens.Face.mono)
                        .foregroundStyle(Tokens.Ink.ink.color)
                        .frame(width: 42, alignment: .trailing)
                        .padding(.vertical, 5)
                        .padding(.horizontal, Tokens.Space.sm)
                        .background(
                            RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                                .fill(Tokens.Ink.window.color)
                                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                                    .strokeBorder(Tokens.Ink.line.color, lineWidth: 1))
                        )
                }
            }

            if stage.target.hasPixels {
                FieldLabel("Longest edge")
                NumberField(value: $stage.longestEdge, suffix: "px",
                            range: 0...20_000, step: 128, zeroPlaceholder: "Original size")

                FieldLabel("Target size")
                NumberField(value: $stage.targetKilobytes, suffix: "KB",
                            range: 0...200_000, step: 50, zeroPlaceholder: "Off")
            }

            // "Adjust for content" is not a setting any more — the behaviour is hard-wired on,
            // and this line says so rather than leaving a toggle nobody should turn off.
            if stage.target.hasQuality {
                HStack(spacing: Tokens.Space.xs) {
                    Image(systemName: Symbols.smart)
                        .font(.system(size: 10))
                    Text("Smart quality — always on.")
                        .font(Tokens.Face.body)
                }
                .foregroundStyle(Tokens.Ink.inkTertiary.color)
            }
        }
        .padding(Tokens.Space.lg)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                .fill(Tokens.Ink.sidebarSunken.color)
        )
    }

    private var imageFormat: Binding<ImageFormat> {
        Binding(get: { if case .image(let f) = stage.target { return f }; return .keep },
                set: { stage.target = .image($0) })
    }

    private var audioFormat: Binding<AudioFormat> {
        Binding(get: { if case .audio(let f) = stage.target { return f }; return .keep },
                set: { stage.target = .audio($0) })
    }

    private var videoFormat: Binding<VideoFormat> {
        Binding(get: { if case .video(let f) = stage.target { return f }; return .keep },
                set: { stage.target = .video($0) })
    }
}

/// The Unpack stage's controls. An archive defaults to being opened — a user who drops a zip
/// almost always wants what is inside made smaller, not the zip re-zipped — but the choice has to
/// be reachable, because the other reading is legitimate.
struct UnpackStageEditor: View {
    @Binding var stage: UnpackStage

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.md) {
            FieldLabel("What to do with the archive")
            PaletteSegmented(options: [(true, "Open it"), (false, "Leave it packed")],
                             selection: $stage.enabled)

            Text(stage.enabled
                 ? "The contents are re-encoded and packed back into one archive."
                 : "The archive is treated as a single file. Already-compressed contents cannot be squeezed further, so this usually changes nothing.")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.Ink.inkTertiary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Tokens.Space.lg)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                .fill(Tokens.Ink.sidebarSunken.color)
        )
    }
}

/// The Bundle stage's controls: how hard to squeeze, and what to call the result.
struct BundleStageEditor: View {
    @Binding var stage: BundleStage

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.md) {
            FieldLabel("Pack the results")
            PaletteSegmented(options: [(true, "Into one zip"), (false, "Leave loose")],
                             selection: $stage.enabled)

            if stage.enabled {
                FieldLabel("Effort")
                PaletteSegmented(options: [(1, "Fast"), (6, "Balanced"), (9, "Maximum")],
                                 selection: $stage.level)

                // The most-asked question about this app, answered where the choice is made rather
                // than in a support thread.
                Text(effortNote)
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.Ink.inkTertiary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Tokens.Space.lg)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                .fill(Tokens.Ink.sidebarSunken.color)
        )
    }

    private var effortNote: String {
        switch stage.level {
        case ...1:
            return "For photos, video and PDFs — data with no redundancy left. Produces the same size as Maximum, in a fraction of the time."
        case 9:
            return "Only worth it for text, code and raw data. On already-compressed files it adds container overhead and takes far longer for nothing."
        default:
            return "A reasonable middle for mixed contents."
        }
    }
}

/// "Save as my defaults" — takes whatever the user just changed in this plan and makes it the
/// starting point for the next drop. Without it every batch begins by re-making the same edits,
/// and the settings window becomes the only way to change anything permanently.
struct SaveAsDefaultsButton: View {
    let plan: Blueprint
    @EnvironmentObject private var defaults: Defaults
    @State private var justSaved = false

    var body: some View {
        // Nothing to save when the plan already is the defaults — say so rather than offering a
        // button that would do nothing.
        let unchanged = defaults.matches(plan)
        Button {
            defaults.adopt(plan)
            withAnimation(Tokens.Motion.quick) { justSaved = true }
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation(Tokens.Motion.quick) { justSaved = false }
            }
        } label: {
            Text(justSaved ? "Saved as your defaults" : "Save as my defaults")
                .font(Tokens.Face.body)
                .foregroundStyle(justSaved ? Tokens.Ink.green.color
                                 : (unchanged ? Tokens.Ink.inkTertiary.color : Tokens.Ink.accent.color))
                .frame(maxWidth: .infinity)
                .padding(.vertical, Tokens.Space.xs)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(unchanged || justSaved)
        .help("Start every future drop with these settings")
    }
}

/// Field labels are **sentence case**. Only group headings are uppercase — when both were, the
/// sidebar had no hierarchy at all.
struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Tokens.Face.body)
            .foregroundStyle(Tokens.Ink.ink.color)
    }
}

// MARK: - Scrub picker

struct ScrubLevelPicker: View {
    @Binding var level: ScrubLevel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            ForEach(ScrubLevel.allCases) { option in
                Button {
                    withAnimation(Tokens.Motion.quick) { level = option }
                } label: {
                    HStack(alignment: .top, spacing: Tokens.Space.sm) {
                        Image(systemName: option == level ? Symbols.radioOn : "circle")
                            .font(.system(size: 12))
                            .foregroundStyle(option == level ? Tokens.Ink.accent.color : Tokens.Ink.inkTertiary.color)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: Tokens.Space.xs) {
                                Text(option.title)
                                    .font(Tokens.Face.body)
                                    .foregroundStyle(Tokens.Ink.ink.color)
                                if option.isDefault {
                                    Text("· default")
                                        .font(Tokens.Face.body)
                                        .foregroundStyle(Tokens.Ink.accent.color)
                                }
                            }
                            if option == level {
                                Text(option.explanation)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Tokens.Ink.inkSecondary.color)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(Tokens.Space.sm)
                    .background(
                        RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                            .fill(option == level ? Tokens.Ink.accentTint.color : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
