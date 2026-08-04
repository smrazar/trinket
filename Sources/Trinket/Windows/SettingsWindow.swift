import SwiftUI

/// Everything that left the sidebar lives here. macOS HIG tabbed preferences.
///
/// The split is a rule, not a habit: **the sidebar carries every setting that changes what *this*
/// conversion produces**; Settings carries the standing defaults a new drop starts from, plus the
/// things that are not about a conversion at all. A setting in both places reads as the same
/// control twice and the two disagree the moment one is changed.
struct SettingsWindow: View {
    @EnvironmentObject private var defaults: Defaults
    @State private var tab: Tab = .general

    enum Tab: String, CaseIterable, Identifiable {
        case general, images, documents, media, scrub, log
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general:   return "General"
            case .images:    return "Images"
            case .documents: return "Documents"
            case .media:     return "Media"
            case .scrub:     return "Scrub"
            case .log:       return "Log"
            }
        }

        var icon: String {
            switch self {
            case .general:   return Symbols.settings
            case .images:    return Symbols.image
            case .documents: return Symbols.document
            case .media:     return Symbols.audio
            case .scrub:     return Symbols.scrub
            case .log:       return Symbols.log
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.xxl) {
                    switch tab {
                    case .general:   general
                    case .images:    images
                    case .documents: documents
                    case .media:     media
                    case .scrub:     scrub
                    case .log:       log
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Tokens.Space.panel)
            }
        }
        // Wide enough that a two-line explanation still has room beside the 200pt control column.
        .frame(width: 640, height: 560)
        .background(Tokens.Ink.sidebar.color)
    }

    private var tabBar: some View {
        HStack(spacing: Tokens.Space.xs) {
            ForEach(Tab.allCases) { option in
                Button {
                    withAnimation(Tokens.Motion.quick) { tab = option }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: option.icon).font(.system(size: 15))
                        Text(option.title).font(.system(size: 11))
                    }
                    .foregroundStyle(tab == option ? Tokens.Ink.accent.color : Tokens.Ink.inkSecondary.color)
                    .frame(width: 72, height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                            .fill(tab == option ? Tokens.Ink.accentTint.color : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, Tokens.Space.lg)
        .padding(.vertical, Tokens.Space.sm)
    }

    // MARK: - Tabs

    private var general: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xxl) {
            SettingsGroup("Output") {
                SettingsRow("Save results to", detail: defaults.outputLocation.note) {
                    PaletteMenu(options: OutputLocation.allCases.map { ($0, $0.title, nil) },
                                selection: $defaults.outputLocation)
                }

                // The folder only matters when results are going to one; the path needs the whole
                // width to itself rather than being crushed into the control column beside a button.
                if defaults.outputLocation == .folder {
                    VStack(alignment: .leading, spacing: Tokens.Space.sm) {
                        SettingsRow("Folder") {
                            SecondaryButton(title: "Choose…", fillsWidth: false, action: chooseFolder)
                        }
                        PathLabel(path: defaults.outputFolderDisplay)
                            .padding(.horizontal, Tokens.Space.xl)
                            .padding(.bottom, Tokens.Space.md)
                    }
                }
                SettingsRow("The original file",
                            detail: originalWarning) {
                    PaletteMenu(options: OriginalHandling.allCases.map { ($0, $0.title, nil) },
                                selection: $defaults.originalHandling)
                }
            }

            SettingsGroup("Appearance") {
                SettingsRow("Window frost") {
                    PaletteSegmented(options: [(true, "Frosted"), (false, "Solid")],
                                     selection: $defaults.windowFrost)
                }
                SettingsRow("Show floating results",
                            detail: "A compact result card after each batch.") {
                    PaletteToggle(isOn: $defaults.floatingResults)
                }
            }

            RenamingSection(renaming: $defaults.renaming)

            SecondaryButton(title: "Reset everything to defaults", fillsWidth: false) {
                defaults.resetToFactory()
            }
        }
    }

    /// Anything that removes the user's file says so plainly, right where the choice is made.
    private var originalWarning: String {
        switch defaults.originalHandling {
        case .keep:    return "Your file is left exactly where it is."
        case .trash:   return "The original goes to the Trash once a result exists."
        case .replace: return "The original goes to the Trash and the result takes its place."
        }
    }

    private var images: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xxl) {
            SettingsGroup("Image defaults") {
                SettingsRow("Convert to", detail: "Applied to every image unless the plan overrides it.") {
                    PaletteMenu(options: ImageFormat.writable.map { ($0, $0.title, nil) },
                                selection: $defaults.imageFormat)
                }
                SettingsRow("Quality") {
                    HStack(spacing: Tokens.Space.md) {
                        PaletteSlider(value: $defaults.quality, range: 0.1...1.0)
                        Text("\(Int((defaults.quality * 100).rounded()))%")
                            .font(Tokens.Face.mono)
                            .foregroundStyle(Tokens.Ink.ink.color)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                SettingsRow("Longest edge") {
                    NumberField(value: $defaults.longestEdge, suffix: "px",
                                range: 0...20_000, step: 128, zeroPlaceholder: "Original")
                }
                SettingsRow("Target size") {
                    NumberField(value: $defaults.targetKilobytes, suffix: "KB",
                                range: 0...200_000, step: 50, zeroPlaceholder: "Off")
                }
            }

            // "Adjust for content" used to be a toggle here. It is hard-wired on now — a setting
            // whose off state nobody should choose is not a setting.
            Label("Quality is nudged per image automatically — a screenshot and a photograph do not want the same setting.",
                  systemImage: Symbols.smart)
                .font(Tokens.Face.body)
                .foregroundStyle(Tokens.Ink.inkTertiary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var documents: some View {
        SettingsGroup("Document defaults") {
            SettingsRow("Convert to", detail: "PDFs are rebuilt; their revision history goes with the rewrite.") {
                PaletteMenu(options: DocumentFormat.allCases.map { ($0, $0.title, nil) },
                            selection: $defaults.documentFormat)
            }
        }
    }

    private var media: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xxl) {
            SettingsGroup("Audio") {
                SettingsRow("Convert to") {
                    PaletteMenu(options: AudioFormat.available.map { ($0, $0.title, nil) },
                                selection: $defaults.audioFormat)
                }
            }

            SettingsGroup("Video") {
                if Shell.hasFFmpeg {
                    SettingsRow("Convert to") {
                        PaletteMenu(options: VideoFormat.allCases.map { ($0, $0.title, nil) },
                                    selection: $defaults.videoFormat)
                    }
                } else {
                    // Say what is missing rather than showing a picker that cannot work.
                    Label("This build did not ship with ffmpeg, so video passes through unchanged.",
                          systemImage: Symbols.notYet)
                        .font(Tokens.Face.body)
                        .foregroundStyle(Tokens.Ink.amber.color)
                }
            }

            if !Shell.hasFFmpeg {
                Label("MP3, Opus and Ogg Vorbis also need ffmpeg — macOS cannot write those on its own.",
                      systemImage: Symbols.info)
                    .font(Tokens.Face.body)
                    .foregroundStyle(Tokens.Ink.inkTertiary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var scrub: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.lg) {
            GroupHeading(text: "Default scrub level")
            Text("What a new drop starts with. Every plan can change it before running.")
                .font(Tokens.Face.body)
                .foregroundStyle(Tokens.Ink.inkSecondary.color)
            ScrubLevelPicker(level: $defaults.scrubLevel)
                .padding(Tokens.Space.lg)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                        .fill(Tokens.Ink.window.color)
                        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                            .strokeBorder(Tokens.Ink.line.color, lineWidth: 1))
                )

            // The measured ceiling, not a guess. PDFKit re-injects these on every write.
            Label("PDFs keep a producer name and a timestamp whichever level you choose — macOS writes those back and offers no way to stop it.",
                  systemImage: Symbols.info)
                .font(Tokens.Face.body)
                .foregroundStyle(Tokens.Ink.inkTertiary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var log: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.lg) {
            SettingsGroup("Log") {
                SettingsRow("Log file", detail: Logbook.shared.displayPath) {
                    SecondaryButton(title: "Show in Finder", fillsWidth: false) {
                        NSWorkspace.shared.activateFileViewerSelecting([Logbook.shared.fileURL])
                    }
                }
                SettingsRow("Session log", detail: "\(Logbook.shared.lines.count) lines this session.") {
                    SecondaryButton(title: "Clear", fillsWidth: false) { Logbook.shared.clear() }
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = defaults.outputFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        defaults.outputFolderPath = url.path
    }
}

// MARK: - Parts

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.sm) {
            GroupHeading(text: title)
            VStack(spacing: 0) { content }
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                        .fill(Tokens.Ink.window.color)
                        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                            .strokeBorder(Tokens.Ink.line.color, lineWidth: 1))
                )
        }
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let control: Control

    /// Every control in the window occupies the same right-hand column, so the picker on one row
    /// lines up with the button on the next. Without this each row sizes to its own control and
    /// the column edge zigzags down the window.
    static var controlColumn: CGFloat { 200 }

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.xl) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Tokens.Face.body)
                    .foregroundStyle(Tokens.Ink.ink.color)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Tokens.Ink.inkTertiary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            control
                .frame(width: Self.controlColumn, alignment: .trailing)
        }
        .padding(.horizontal, Tokens.Space.xl)
        .padding(.vertical, Tokens.Space.lg)
    }
}

/// A filesystem path shown in a control column. Truncating the *middle* keeps both the meaningful
/// start and the folder name itself — `…wnloads/trinket` loses the one word that identifies it.
struct PathLabel: View {
    let path: String

    var body: some View {
        Text(path)
            .font(Tokens.Face.mono)
            .foregroundStyle(Tokens.Ink.inkSecondary.color)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(path)
    }
}
