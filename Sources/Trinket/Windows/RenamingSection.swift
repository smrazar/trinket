import SwiftUI

/// The renaming controls, with a live **Original → Renamed** table.
///
/// The table is the point. PowerRename and the Finder's own batch rename both lead with it, for
/// the same reason: a rename that surprises you has already happened by the time you notice. It
/// runs the same `apply` the run does, so what is shown cannot drift from what is written.
struct RenamingSection: View {
    @Binding var renaming: Renaming
    /// The real files, when there are any. Falls back to examples so the table is never empty.
    var files: [(name: String, ext: String, kind: Kind)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.sm) {
            GroupHeading(text: "Renaming")

            VStack(spacing: 0) {
                SettingsRow("Rename results",
                            detail: renaming.isEnabled
                                ? "Applies to the copies trinket writes. Your originals keep their names."
                                : "Results keep the name they came in with.") {
                    PaletteToggle(isOn: $renaming.isEnabled)
                }

                if renaming.isEnabled {
                    Hairline()
                    controls
                }
            }
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                    .fill(Tokens.Ink.window.color)
                    .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                        .strokeBorder(Tokens.Ink.line.color, lineWidth: 1))
            )
        }
    }

    @ViewBuilder
    private var controls: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.lg) {
            PaletteSegmented(options: Renaming.Mode.allCases.map { ($0, $0.title) },
                             selection: $renaming.mode)

            switch renaming.mode {
            case .findReplace: findReplace
            case .addText:     addText
            case .template:    template
            }

            shared
            PreviewTable(rows: renaming.previewRows(for: sampleFiles))
        }
        .padding(Tokens.Space.xl)
    }

    // MARK: - Modes

    private var findReplace: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.md) {
            FieldLabel("Find")
            PlainField(text: $renaming.find, placeholder: "text to look for")

            FieldLabel("Replace with")
            PlainField(text: $renaming.replaceWith, placeholder: "leave empty to delete it")

            Text("`{n}` in the replacement numbers the batch.")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.Ink.inkTertiary.color)

            VStack(alignment: .leading, spacing: Tokens.Space.sm) {
                CheckRow("Use regular expressions", isOn: $renaming.isRegex)
                CheckRow("Match all occurrences", isOn: $renaming.matchAll)
                CheckRow("Case sensitive", isOn: $renaming.isCaseSensitive)
            }

            FieldLabel("Apply to")
            PaletteMenu(options: Renaming.Target.allCases.map { ($0, $0.title, nil) },
                        selection: $renaming.applyTo)
        }
    }

    private var addText: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.md) {
            FieldLabel("Text to add")
            PlainField(text: $renaming.addition, placeholder: "-edited")
            PaletteSegmented(options: Renaming.Position.allCases.map { ($0, $0.title) },
                             selection: $renaming.additionPosition)
        }
    }

    private var template: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.md) {
            FieldLabel("Pattern")
            PlainField(text: $renaming.pattern, placeholder: "{name}")

            // Clicking a chip appends its token, so a pattern can be built without typing braces
            // correctly. Each carries its meaning as a tooltip — a nine-line glossary underneath
            // pushed the preview table off the bottom of the sheet, and the preview is the part
            // that actually answers "what will my files be called".
            FlowTokens(tokens: Renaming.tokens) { token in
                renaming.pattern += token
            }
        }
    }

    // MARK: - Shared

    private var shared: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.md) {
            Hairline()

            HStack(spacing: Tokens.Space.lg) {
                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                    FieldLabel("Number from")
                    NumberField(value: $renaming.startAt, suffix: "", range: 0...100_000, step: 1)
                }
                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                    FieldLabel("Digits")
                    NumberField(value: $renaming.digits, suffix: "", range: 1...8, step: 1)
                }
                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                    FieldLabel("Spaces")
                    PlainField(text: $renaming.spaceReplacement, placeholder: "keep")
                }
            }

            FieldLabel("Text formatting")
            PaletteSegmented(options: Renaming.CaseStyle.allCases.map { ($0, $0.short) },
                             selection: $renaming.caseStyle)
        }
    }

    /// Real files when the window has some, examples otherwise — the table must never be empty,
    /// because an empty table is exactly when someone assumes nothing will change.
    private var sampleFiles: [(name: String, ext: String, kind: Kind)] {
        guard files.isEmpty else { return Array(files.prefix(8)) }
        return [("IMG_2087", "jpg", .image),
                ("IMG_2093", "jpg", .image),
                ("Scan 001", "pdf", .document)]
    }
}

/// The renaming controls as a sheet, opened from the plan sidebar so the decision sits with every
/// other per-run decision rather than only in Settings.
struct RenamingSheet: View {
    @Binding var renaming: Renaming
    let files: [(name: String, ext: String, kind: Kind)]
    let onClose: () -> Void

    var body: some View {
        SheetFrame(title: "Rename results", width: 700, height: 680, onClose: onClose) {
            RenamingSection(renaming: $renaming, files: files)
        }
    }
}

/// The Original → Renamed table.
struct PreviewTable: View {
    let rows: [Renaming.PreviewRow]

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.sm) {
            HStack {
                GroupHeading(text: "Preview")
                Spacer()
                if !rows.contains(where: \.changed) {
                    // Say it rather than showing two identical columns and leaving them to notice.
                    Text("nothing would change")
                        .font(.system(size: 11))
                        .foregroundStyle(Tokens.Ink.amber.color)
                }
            }

            VStack(spacing: 0) {
                ForEach(rows) { row in
                    HStack(spacing: Tokens.Space.sm) {
                        Text(row.before)
                            .font(Tokens.Face.mono)
                            .foregroundStyle(Tokens.Ink.inkTertiary.color)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: Symbols.rightArrow)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Tokens.Ink.inkTertiary.color)
                        Text(row.after)
                            .font(row.changed ? Tokens.Face.monoStrong : Tokens.Face.mono)
                            .foregroundStyle(row.changed ? Tokens.Ink.accent.color
                                             : Tokens.Ink.inkTertiary.color)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 5)
                    Hairline()
                }
            }
            .padding(.horizontal, Tokens.Space.md)
            .padding(.vertical, Tokens.Space.sm)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                    .fill(Tokens.Ink.sidebarSunken.color)
            )
        }
    }
}

// MARK: - Small controls

/// A text field drawn from the palette. The stock one paints its focus ring in the system accent.
struct PlainField: View {
    @Binding var text: String
    var placeholder = ""

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder)
            .foregroundColor(Tokens.Ink.inkTertiary.color))
            .textFieldStyle(.plain)
            .font(Tokens.Face.mono)
            .foregroundStyle(Tokens.Ink.ink.color)
            .focused($isFocused)
            .focusEffectDisabled()
            .padding(.horizontal, Tokens.Space.md)
            .padding(.vertical, Tokens.Space.sm)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                    .fill(Tokens.Ink.window.color)
                    .overlay(
                        RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                            .strokeBorder(isFocused ? Tokens.Ink.accent.color : Tokens.Ink.line.color,
                                          lineWidth: isFocused ? 1.5 : 1)
                    )
            )
            .animation(Tokens.Motion.quick, value: isFocused)
    }
}

/// A checkbox. The stock `Toggle` with `.checkbox` style paints in the system accent.
struct CheckRow: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        Button {
            withAnimation(Tokens.Motion.quick) { isOn.toggle() }
        } label: {
            HStack(spacing: Tokens.Space.sm) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(isOn ? Tokens.Ink.accent.color : Tokens.Ink.window.color)
                    .frame(width: 14, height: 14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(isOn ? .clear : Tokens.Ink.borderStrong.color, lineWidth: 1)
                    )
                    .overlay {
                        if isOn {
                            Image(systemName: Symbols.tick)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Tokens.Ink.onAccent.color)
                        }
                    }
                Text(title)
                    .font(Tokens.Face.body)
                    .foregroundStyle(Tokens.Ink.ink.color)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The clickable token chips above the pattern field. Each explains itself on hover rather than
/// through a glossary block, which is what keeps the preview table on screen.
struct FlowTokens: View {
    let tokens: [(token: String, meaning: String)]
    let onTap: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 74), spacing: Tokens.Space.xs)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Tokens.Space.xs) {
            ForEach(tokens, id: \.token) { entry in
                Button { onTap(entry.token) } label: {
                    Text(entry.token)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Tokens.Ink.accent.color)
                        .padding(.horizontal, Tokens.Space.sm)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: Tokens.Radius.sm - 1, style: .continuous)
                                .fill(Tokens.Ink.accentSoft.color)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(entry.token) — \(entry.meaning)")
            }
        }
    }
}
