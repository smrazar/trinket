import SwiftUI
import AppKit

/// Every control the app draws, built from the palette.
///
/// Nothing here uses a stock control. `.toggleStyle(.switch)`, `.pickerStyle(.segmented)` and a
/// plain `Slider` all paint in the *system* accent — whatever colour the user picked in System
/// Settings — which puts a stranger's blue next to trinket's azure. And anything focusable draws
/// the stock focus ring in that same system accent, which reads as a blue bar across the window,
/// so every focusable view here pairs `.focusable()` with `.focusEffectDisabled()`.

// MARK: - Buttons

/// The one accent button on screen: Run plan, Choose Files, Show in Finder.
struct PrimaryButton: View {
    let title: String
    var icon: String?
    var isEnabled = true
    /// False when the button sizes to its own text — a `.fixedSize()` caller. It still needs
    /// horizontal padding, or the label is pressed flat against both edges.
    var fillsWidth = true
    let action: () -> Void

    @State private var isPressed = false
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Space.sm) {
                if let icon { Image(systemName: icon).font(.system(size: 13, weight: .semibold)) }
                Text(title).font(Tokens.Face.bodyStrong)
            }
            .foregroundStyle(Tokens.Ink.onAccent.color)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .padding(.vertical, Tokens.Space.md)
            .padding(.horizontal, Tokens.Space.xxl)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                    .fill(fill)
            )
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovering = $0 }
        .pressAction { isPressed = $0 }
        .animation(Tokens.Motion.quick, value: isPressed)
        .animation(Tokens.Motion.quick, value: isHovering)
    }

    private var fill: Color {
        if isPressed { return Tokens.Ink.accentPress.color }
        if isHovering { return Tokens.Ink.accentPress.color.opacity(0.9) }
        return Tokens.Ink.accent.color
    }
}

/// The quieter partner: New batch, Cancel, Choose…
struct SecondaryButton: View {
    let title: String
    var icon: String?
    var isDestructive = false
    var fillsWidth = true
    let action: () -> Void

    @State private var isPressed = false
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Space.sm) {
                if let icon { Image(systemName: icon).font(.system(size: 12, weight: .medium)) }
                Text(title).font(Tokens.Face.body)
            }
            .foregroundStyle(isDestructive ? Tokens.Ink.red.color : Tokens.Ink.ink.color)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .padding(.vertical, Tokens.Space.sm + 2)
            .padding(.horizontal, fillsWidth ? 0 : Tokens.Space.md)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                    .fill(isPressed ? Tokens.Ink.chip.color : Tokens.Ink.window.color)
                    .overlay(
                        RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                            .strokeBorder(isHovering ? Tokens.Ink.inkTertiary + 0.5 : Tokens.Ink.line.color,
                                          lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .pressAction { isPressed = $0 }
        .animation(Tokens.Motion.quick, value: isPressed)
    }
}

/// A toolbar glyph. Reads as selected when its panel is open.
struct ToolbarButton: View {
    let icon: String
    let help: String
    var isSelected = false
    var isEnabled = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? Tokens.Ink.accent.color : Tokens.Ink.inkSecondary.color)
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                        .fill(background)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { isHovering = $0 }
        .help(help)
        .animation(Tokens.Motion.quick, value: isSelected)
    }

    private var background: Color {
        if isSelected { return Tokens.Ink.accentTint.color }
        if isHovering { return Tokens.Ink.chip + 0.6 }
        return .clear
    }
}

// MARK: - Toggle

/// The switch, drawn from the palette. `.toggleStyle(.switch)` renders in the system accent.
struct PaletteToggle: View {
    @Binding var isOn: Bool
    var isEnabled = true

    var body: some View {
        Button {
            withAnimation(Tokens.Motion.quick) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Tokens.Ink.accent.color : Tokens.Ink.chip.color)
                    .frame(width: 40, height: 24)
                Circle()
                    .fill(.white)
                    .frame(width: 20, height: 20)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                    .padding(2)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

// MARK: - Segmented

/// The segmented control. `.pickerStyle(.segmented)` paints its selection in the system accent.
struct PaletteSegmented<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selection
                Button {
                    withAnimation(Tokens.Motion.quick) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(Tokens.Face.body)
                        .foregroundStyle(isSelected ? Tokens.Ink.ink.color : Tokens.Ink.inkSecondary.color)
                        .padding(.vertical, 5)
                        .padding(.horizontal, Tokens.Space.md)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: Tokens.Radius.sm - 2, style: .continuous)
                                .fill(isSelected ? Tokens.Ink.window.color : .clear)
                                .shadow(color: isSelected ? .black.opacity(0.10) : .clear, radius: 1, y: 0.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                .fill(Tokens.Ink.chip.color)
        )
    }
}

// MARK: - Slider

/// The quality slider. A stock `Slider` fills in the system accent.
struct PaletteSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1

    @State private var isDragging = false

    private let track: CGFloat = 4
    private let knob: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let fraction = ((value - range.lowerBound) / (range.upperBound - range.lowerBound))
                .clamped(0, 1)
            let travel = width - knob

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Tokens.Ink.chip.color)
                    .frame(height: track)
                Capsule()
                    .fill(Tokens.Ink.accent.color)
                    .frame(width: knob / 2 + travel * fraction, height: track)
                Circle()
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(isDragging ? 0.25 : 0.15),
                            radius: isDragging ? 3 : 1.5, y: 0.5)
                    .overlay(Circle().strokeBorder(Tokens.Ink.line.color, lineWidth: 0.5))
                    .offset(x: travel * fraction)
            }
            .frame(height: knob)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            // A click anywhere on the track jumps to that value, which is what a stock slider
            // does and what everyone expects.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isDragging = true
                        let position = ((drag.location.x - knob / 2) / travel).clamped(0, 1)
                        value = range.lowerBound + position * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in isDragging = false }
            )
        }
        .frame(height: knob)
    }
}

// MARK: - Number field

/// A number entry with a stepper, for longest edge and target size. The stock `TextField` draws a
/// focus ring in the system accent, so focus is shown with the accent border instead.
struct NumberField: View {
    @Binding var value: Int
    var suffix: String
    var range: ClosedRange<Int> = 0...100_000
    var step: Int = 1
    /// Shown when the value is 0 — "Off" reads better than a zero the user has to interpret.
    var zeroPlaceholder: String?

    @FocusState private var isFocused: Bool
    @State private var text: String = ""

    var body: some View {
        HStack(spacing: Tokens.Space.xs) {
            TextField("", text: $text, prompt: prompt)
                .textFieldStyle(.plain)
                .font(Tokens.Face.mono)
                .foregroundStyle(Tokens.Ink.ink.color)
                .focused($isFocused)
                .focusEffectDisabled()
                .onSubmit(commit)
                .onChange(of: isFocused) { _, focused in if !focused { commit() } }

            if !suffix.isEmpty {
                Text(suffix)
                    .font(Tokens.Face.mono)
                    .foregroundStyle(Tokens.Ink.inkTertiary.color)
            }

            Stepper("", value: Binding(get: { value },
                                       set: { value = $0.clamped(range.lowerBound, range.upperBound); sync() }),
                    in: range, step: step)
                .labelsHidden()
                .focusEffectDisabled()
        }
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
        .onAppear(perform: sync)
        .onChange(of: value) { _, _ in if !isFocused { sync() } }
        .animation(Tokens.Motion.quick, value: isFocused)
    }

    private var prompt: Text? {
        guard let zeroPlaceholder else { return nil }
        return Text(zeroPlaceholder).foregroundColor(Tokens.Ink.inkTertiary.color)
    }

    private func sync() {
        text = (value == 0 && zeroPlaceholder != nil) ? "" : String(value)
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty, zeroPlaceholder != nil {
            value = 0
        } else if let parsed = Int(trimmed) {
            value = parsed.clamped(range.lowerBound, range.upperBound)
        }
        // A value that could not be parsed snaps back rather than silently becoming zero.
        sync()
    }
}

// MARK: - Menu

/// A dropdown. A SwiftUI `Menu` is only clickable where its **label** is — no outer `.frame`,
/// `.contentShape` or stretched `Color.clear` label extends its hit area, so a full-width menu
/// responds only near the text. This wraps a `Button` around a real `NSMenu`, which is clickable
/// across every pixel it covers.
struct PaletteMenu<Value: Hashable>: View {
    let options: [(value: Value, title: String, note: String?)]
    @Binding var selection: Value
    var width: CGFloat?

    @State private var isHovering = false

    var body: some View {
        Button(action: present) {
            HStack(spacing: Tokens.Space.sm) {
                Text(title)
                    .font(Tokens.Face.body)
                    .foregroundStyle(Tokens.Ink.ink.color)
                    .lineLimit(1)
                Spacer(minLength: Tokens.Space.sm)
                Image(systemName: Symbols.menuChevron)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Tokens.Ink.inkTertiary.color)
            }
            .padding(.horizontal, Tokens.Space.md)
            .padding(.vertical, Tokens.Space.sm)
            // Fills whatever column it is given rather than hugging its longest title, so a
            // window of menus has one right edge instead of a ragged one.
            .frame(maxWidth: width ?? .infinity)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                    .fill(Tokens.Ink.window.color)
                    .overlay(
                        RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                            .strokeBorder(isHovering ? Tokens.Ink.inkTertiary + 0.5 : Tokens.Ink.line.color,
                                          lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var title: String {
        options.first { $0.value == selection }.map { option in
            option.note.map { "\(option.title) — \($0)" } ?? option.title
        } ?? ""
    }

    private func present() {
        let menu = NSMenu()
        // `NSMenuItem.target` is a weak reference, so the target has to be kept alive by
        // something else for as long as the menu is up. `popUpContextMenu` blocks until the menu
        // closes, so this local does exactly that — but only because the call is synchronous. If
        // this ever becomes an async presentation, the target needs a real owner.
        let target = MenuTarget()
        target.onPick = { index in
            guard options.indices.contains(index) else { return }
            selection = options[index].value
        }

        for (index, option) in options.enumerated() {
            let item = NSMenuItem(title: option.note.map { "\(option.title) — \($0)" } ?? option.title,
                                  action: #selector(MenuTarget.pick(_:)), keyEquivalent: "")
            item.state = option.value == selection ? .on : .off
            item.tag = index
            item.target = target
            menu.addItem(item)
        }

        if let event = NSApp.currentEvent, let view = NSApp.keyWindow?.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
    }
}

/// Receives the pick from a real `NSMenu`. Non-generic, because a generic type cannot hold the
/// static storage an `@objc` target needs, and because the index is all that has to cross over.
private final class MenuTarget: NSObject {
    var onPick: ((Int) -> Void)?
    @objc func pick(_ sender: NSMenuItem) { onPick?(sender.tag) }
}

// MARK: - Small parts

/// The kind badge: charcoal on a recessed chip, never accent, and it hugs its text rather than
/// sitting in a fixed 62pt frame.
struct KindBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Tokens.Face.label)
            .tracking(Tokens.Face.labelTracking)
            .foregroundStyle(Tokens.Ink.chipInk.color)
            .padding(.horizontal, Tokens.Space.sm)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.sm - 1, style: .continuous)
                    .fill(Tokens.Ink.chip.color)
            )
            .fixedSize()
    }
}

/// The savings pill — accent-tinted, and only ever shown when there is a real saving.
struct SavingsPill: View {
    let percent: Int

    var body: some View {
        Text("\(percent)%")
            .font(Tokens.Face.monoStrong)
            .foregroundStyle(Tokens.Ink.accent.color)
            .padding(.horizontal, Tokens.Space.sm)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.sm - 1, style: .continuous)
                    .fill(Tokens.Ink.accentTint.color)
            )
            .fixedSize()
    }
}

/// An amber or red tag: `Not yet · passes through`, `Unchanged`, `Queued`.
struct StatusTag: View {
    enum Tone { case amber, red, quiet }

    let text: String
    var tone: Tone = .amber
    var icon: String?

    var body: some View {
        HStack(spacing: Tokens.Space.xs) {
            if let icon {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            }
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, Tokens.Space.sm)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.sm - 1, style: .continuous)
                .fill(background)
        )
        .fixedSize()
    }

    private var foreground: Color {
        switch tone {
        case .amber: return Tokens.Ink.amber.color
        case .red:   return Tokens.Ink.red.color
        case .quiet: return Tokens.Ink.inkTertiary.color
        }
    }

    private var background: Color {
        switch tone {
        case .amber: return Tokens.Ink.amber + 0.14
        case .red:   return Tokens.Ink.red + 0.12
        case .quiet: return Tokens.Ink.chip + 0.7
        }
    }
}

/// An uppercase group heading — the app's only uppercase tier.
struct GroupHeading: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(Tokens.Face.label)
            .tracking(Tokens.Face.labelTracking)
            .foregroundStyle(Tokens.Ink.inkTertiary.color)
    }
}

/// A hairline. `Divider()` picks up the system separator colour, which is not in the palette.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Tokens.Ink.line.color)
            .frame(height: 1)
    }
}

// MARK: - Helpers

extension View {
    /// Press tracking without a `ButtonStyle`, so a button can keep `.plain` and still know.
    func pressAction(_ handler: @escaping (Bool) -> Void) -> some View {
        modifier(PressModifier(handler: handler))
    }
}

private struct PressModifier: ViewModifier {
    let handler: (Bool) -> Void

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in handler(true) }
                .onEnded { _ in handler(false) }
        )
    }
}
