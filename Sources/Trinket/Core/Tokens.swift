import AppKit
import SwiftUI

/// The palette, carried over from the shared design language the whole app family uses — same
/// authoring split as before: **the accent family is authored in OKLCH** and converted here, **the
/// grey ramp is authored as hex**. The redesign changed the layout, not the colours; a second blue
/// appearing in one app is exactly what this file exists to prevent.
///
/// The accent is the app icon's brightest gem face, `#00a1fe`, converted to OKLCH hue **245.6** —
/// so the icon and the interface agree without a second colour turning up anywhere.
///
/// **The one documented divergence.** The shared light accent is `oklch(0.580 0.190 h)`, which at
/// this hue renders `#007EE2`, and white on it measures **4.13:1 — under WCAG AA's 4.5**. Button
/// labels here are 13pt semibold, which is not "large text" by the WCAG definition, so 4.13 does
/// not pass. `L = 0.550` reaches 4.64 and is what ships. `selfCheck` asserts the **ratio**, not the
/// hex, so it cannot regress quietly.
enum Tokens {}

// MARK: - OKLCH

extension Tokens {
    /// Authoring space for the accent family. Perceptual lightness, so a hover that is "a bit
    /// darker" really is, at every hue.
    struct OKLCH {
        let l: Double, c: Double, h: Double, alpha: Double

        init(_ l: Double, _ c: Double, _ h: Double, alpha: Double = 1) {
            self.l = l; self.c = c; self.h = h; self.alpha = alpha
        }

        var nsColor: NSColor {
            let hue = h * .pi / 180
            let a = c * cos(hue), b = c * sin(hue)
            let lCube = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
            let mCube = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
            let sCube = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)

            let red   =  4.0767416621 * lCube - 3.3077115913 * mCube + 0.2309699292 * sCube
            let green = -1.2684380046 * lCube + 2.6097574011 * mCube - 0.3413193965 * sCube
            let blue  = -0.0041960863 * lCube - 0.7034186147 * mCube + 1.7076147010 * sCube

            func encode(_ channel: Double) -> Double {
                let clamped = min(max(channel, 0), 1)
                return clamped > 0.0031308
                    ? 1.055 * pow(clamped, 1 / 2.4) - 0.055
                    : 12.92 * clamped
            }
            return NSColor(srgbRed: encode(red), green: encode(green), blue: encode(blue), alpha: alpha)
        }
    }
}

// MARK: - Colour

extension Tokens {
    /// A light value and its dark counterpart, resolved per-appearance at draw time.
    struct Duo {
        let light: NSColor
        let dark: NSColor

        var nsColor: NSColor {
            NSColor(name: nil) { $0.isDark ? self.dark : self.light }
        }

        var color: Color { Color(nsColor) }
    }

    enum Ink {
        /// The accent hue, from the icon's brightest face.
        static let accentHue: Double = 245.6

        // The accent marks actions and results ONLY — the Run button, progress fills, the savings
        // pill, the current selection, the finished payoff number. Never a label or a kind badge.
        static let accent = Duo(light: OKLCH(0.550, 0.190, accentHue).nsColor,
                                dark:  OKLCH(0.720, 0.155, accentHue).nsColor)
        static let accentPress = Duo(light: OKLCH(0.510, 0.195, accentHue).nsColor,
                                     dark:  OKLCH(0.760, 0.150, accentHue).nsColor)
        /// The accent at low opacity — savings pill, selected row, tinted wells.
        static let accentSoft = Duo(light: OKLCH(0.550, 0.190, accentHue, alpha: 0.14).nsColor,
                                    dark:  OKLCH(0.720, 0.155, accentHue, alpha: 0.18).nsColor)
        /// What text on an accent fill is drawn in.
        static let onAccent = Duo(light: .white,
                                  dark:  OKLCH(0.200, 0.040, accentHue).nsColor)

        // The shared grey ramp, unchanged from the rest of the family.
        static let bg = Duo(light: .hex(0xFDFDFD), dark: .hex(0x1E1F21))
        static let surface = Duo(light: .hex(0xFFFFFF), dark: .hex(0x28292C))
        static let surfaceSecondary = Duo(light: .hex(0xF3F4F5), dark: .hex(0x333438))
        static let surfaceHover = Duo(light: .hex(0xEDEEF0), dark: .hex(0x3B3C40))
        static let border = Duo(light: .hex(0x000000, alpha: 0.10), dark: .hex(0xFFFFFF, alpha: 0.12))
        static let borderStrong = Duo(light: .hex(0x000000, alpha: 0.16), dark: .hex(0xFFFFFF, alpha: 0.20))
        static let textPrimary = Duo(light: .hex(0x28292B), dark: .hex(0xF0F1F2))
        static let textSecondary = Duo(light: .hex(0x5F6164), dark: .hex(0xA7A9AD))
        static let textTertiary = Duo(light: .hex(0x8A8C8F), dark: .hex(0x7E8085))

        // MARK: Names the redesign introduced
        //
        // These are the surfaces the three-column layout needs that a single-pane app did not.
        // Each is drawn from the ramp above rather than invented, so the family still matches.

        /// The plan sidebar and the toolbar.
        static let sidebar = surfaceSecondary
        /// The well an expanded stage's controls sit in.
        static let sidebarSunken = surfaceHover
        /// The recessed chip behind a kind badge.
        static let chip = surfaceHover
        /// Kind-badge text: charcoal, never accent.
        static let chipInk = textSecondary
        /// The log panel. Flat, no frost — a blurred backdrop behind 12px monospace is where
        /// frost stops being decoration and starts costing legibility.
        static let logBg = Duo(light: .hex(0xFBFBFD), dark: .hex(0x232427))
        static let logInk = textPrimary
        static let line = border

        /// Skipped · not-yet-supported · paused. The mockup's `#f59e0b` measures 2.2:1 on white —
        /// fine as a swatch, unreadable as the words "Not yet · passes through", which is the only
        /// way this colour is ever used. Darkened until it clears AA.
        static let amber = Duo(light: .hex(0xA35F00), dark: .hex(0xFBBF3F))
        /// Failed.
        static let red = Duo(light: .hex(0xD70015), dark: .hex(0xFF6961))
        /// The done tick, and nothing larger. A finished result reads in accent, not green.
        /// Same story as the amber: the mockup's `#34c759` is a swatch colour, not a text colour.
        static let green = Duo(light: .hex(0x178036), dark: .hex(0x40D866))

        // Aliases so view code reads in the redesign's vocabulary without a second set of values.
        static let ink = textPrimary
        static let inkSecondary = textSecondary
        static let inkTertiary = textTertiary
        static let window = surface
        static let accentTint = accentSoft
    }
}

extension Tokens.Duo {
    static func + (lhs: Tokens.Duo, rhs: Double) -> Color { lhs.color.opacity(rhs) }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension NSColor {
    static func hex(_ value: UInt32, alpha: Double = 1) -> NSColor {
        NSColor(srgbRed: Double((value >> 16) & 0xff) / 255,
                green: Double((value >> 8) & 0xff) / 255,
                blue: Double(value & 0xff) / 255,
                alpha: alpha)
    }

    /// Relative luminance, WCAG 2.1 §1.4.3. Used by the self-check, not by drawing code.
    var relativeLuminance: Double {
        guard let srgb = usingColorSpace(.sRGB) else { return 0 }
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(srgb.redComponent)
            + 0.7152 * linear(srgb.greenComponent)
            + 0.0722 * linear(srgb.blueComponent)
    }

    func contrast(against other: NSColor) -> Double {
        let a = relativeLuminance, b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    var hexString: String {
        guard let srgb = usingColorSpace(.sRGB) else { return "#??????" }
        return String(format: "#%02X%02X%02X",
                      Int((srgb.redComponent * 255).rounded()),
                      Int((srgb.greenComponent * 255).rounded()),
                      Int((srgb.blueComponent * 255).rounded()))
    }
}

// MARK: - Type

// One uppercase tier only: group headings. Field labels are sentence case. When both were
// uppercase the sidebar had no hierarchy — do not repeat that.
extension Tokens {
    enum Face {
        /// 28/700 — the payoff number and the empty-state title.
        static let display = Font.system(size: 28, weight: .bold)
        /// 17/600 — stage names and filenames.
        static let heading = Font.system(size: 17, weight: .semibold)
        /// 13/400 — values and descriptions.
        static let body = Font.system(size: 13)
        static let bodyStrong = Font.system(size: 13, weight: .semibold)
        /// 11/600 uppercase with tracking — group headings and kind badges.
        static let label = Font.system(size: 11, weight: .semibold)
        /// 12/400 — the log, and every byte figure, so numbers align.
        static let mono = Font.system(size: 12, design: .monospaced)
        static let monoStrong = Font.system(size: 12, weight: .semibold, design: .monospaced)

        static let labelTracking: CGFloat = 0.6
    }
}

// MARK: - Space

extension Tokens {
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        /// Panel padding.
        static let panel: CGFloat = 28
        static let s32: CGFloat = 32
        static let s40: CGFloat = 40

        /// Card padding.
        static let card: CGFloat = 20
        /// File row: 14 vertical × 16 horizontal.
        static let rowV: CGFloat = 14
        static let rowH: CGFloat = 16
    }

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let full: CGFloat = 9999
    }

    enum Motion {
        /// Stage expand/collapse and progress. 120–160ms ease-out.
        static let stage = Animation.easeOut(duration: 0.14)
        static let quick = Animation.easeOut(duration: 0.12)
    }

    /// Layout breakpoints. Below `comfortable` neither sidebar shows and the plan survives as a
    /// breadcrumb strip; at `comfortable` the plan sidebar opens; above `wide` the log may join.
    enum Width {
        static let minimum: CGFloat = 720
        /// Tall enough that the biggest sheet — the before/after comparison, which carries two
        /// pictures and a table — still fits inside the window that presents it.
        static let minimumHeight: CGFloat = 740
        static let comfortable: CGFloat = 1000
        static let wide: CGFloat = 1240
        static let planSidebar: CGFloat = 248
        static let logSidebar: CGFloat = 300
        /// How far each pane may be dragged. The lower bounds are where the pane stops being
        /// usable — a plan narrower than this truncates its own stage summaries, and a log
        /// narrower than this wraps every line of a timestamped monospace column.
        static let planRange: ClosedRange<CGFloat> = 210...420
        static let logRange: ClosedRange<CGFloat> = 240...480
    }
}

// MARK: - Self-check

extension Tokens {
    static func selfCheck() {
        let white = NSColor.white

        // The accent renders what the shared design language says it renders. If the OKLCH maths
        // is ever "simplified", these fail with the produced hex in the message.
        assert(Ink.accent.light.hexString == "#0075D7",
               "light accent renders \(Ink.accent.light.hexString), expected #0075D7 — recompute, do not hand-edit")
        assert(Ink.accent.dark.hexString == "#3FACFF",
               "dark accent renders \(Ink.accent.dark.hexString), expected #3FACFF")

        // The reason for the one divergence from the shared tokens. Assert the *ratio*, so it
        // cannot regress quietly if someone "restores" L=0.580 from the contract.
        let onWhite = Ink.accent.light.contrast(against: white)
        assert(onWhite >= 4.5,
               "white on the accent is \(onWhite), below WCAG AA 4.5 — do not lighten it")

        // The icon's brightest face is the hue source, not a fill for white text.
        let brand = NSColor.hex(0x00A1FE)
        assert(brand.contrast(against: white) < 4.5,
               "#00a1fe now passes AA — recheck whether it should carry text after all")

        // Kind badges are charcoal on a recessed chip, never accent.
        assert(Ink.chipInk.light.contrast(against: Ink.chip.light) >= 4.5,
               "kind badge text must stay legible on the chip")
        assert(Ink.chipInk.light != Ink.accent.light, "kind badges are never accent")

        // Body text on every surface it actually lands on, in both appearances.
        for (name, surface) in [("surface", Ink.surface), ("sidebar", Ink.sidebar),
                                ("sunken", Ink.sidebarSunken), ("log", Ink.logBg)] {
            let lightRatio = Ink.textPrimary.light.contrast(against: surface.light)
            assert(lightRatio >= 7, "primary text on \(name) is \(lightRatio), want AAA")
            let darkRatio = Ink.textPrimary.dark.contrast(against: surface.dark)
            assert(darkRatio >= 7, "dark primary text on \(name) is \(darkRatio), want AAA")
        }
        let secondary = Ink.textSecondary.light.contrast(against: Ink.sidebar.light)
        assert(secondary >= 4.5, "secondary text on the sidebar is \(secondary), below AA")

        // Status colours have to be readable as *text*, not just distinguishable as swatches —
        // an amber tag at the stock #f59e0b measures 2.2:1 on white and cannot be read.
        for (name, duo) in [("amber", Ink.amber), ("red", Ink.red), ("green", Ink.green)] {
            let ratio = duo.light.contrast(against: Ink.surface.light)
            assert(ratio >= 4.5, "\(name) on a light surface is \(ratio), below AA for text")
            let darkRatio = duo.dark.contrast(against: Ink.bg.dark)
            assert(darkRatio >= 4.5, "\(name) on a dark surface is \(darkRatio), below AA for text")
        }

        // Text on an accent fill, in dark mode too — white on the lighter dark accent would fail.
        let onAccentDark = Ink.onAccent.dark.contrast(against: Ink.accent.dark)
        assert(onAccentDark >= 4.5, "dark on-accent text is \(onAccentDark), below AA")

        assert(Width.minimum < Width.comfortable && Width.comfortable < Width.wide,
               "breakpoints must ascend")
    }
}
