import SwiftUI
import UniformTypeIdentifiers

/// The drop target. The common case is drop → one button → done, so this screen has exactly one
/// call to action and one promise underneath it.
struct EmptyState: View {
    let isTargeted: Bool
    let onChoose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(isTargeted ? Tokens.Ink.accent.color : Tokens.Ink.accent + 0.28)
                    .frame(width: 148, height: 148)
                Circle()
                    .fill(Tokens.Ink.accentTint + (isTargeted ? 0.9 : 0.5))
                    .frame(width: 132, height: 132)
                TrinketMark(size: 62)
                    .scaleEffect(isTargeted ? 1.08 : 1)
            }
            .animation(Tokens.Motion.stage, value: isTargeted)

            Text("Drop files here")
                .font(Tokens.Face.display)
                .foregroundStyle(Tokens.Ink.ink.color)
                .padding(.top, Tokens.Space.xxl)

            Text("Drop anything and trinket proposes a plan —\nsmaller, a different format, and safe to send.")
                .font(Tokens.Face.body)
                .foregroundStyle(Tokens.Ink.inkSecondary.color)
                .multilineTextAlignment(.center)
                .padding(.top, Tokens.Space.sm)

            Text(kindLine)
                .font(Tokens.Face.mono)
                .foregroundStyle(Tokens.Ink.inkTertiary.color)
                .padding(.top, Tokens.Space.lg)

            PrimaryButton(title: "Choose Files…", icon: Symbols.reveal, fillsWidth: false, action: onChoose)
                .fixedSize()
                .padding(.top, Tokens.Space.xxl)

            Label("Everything runs on your Mac. No file ever leaves it.", systemImage: Symbols.offline)
                .font(Tokens.Face.body)
                .foregroundStyle(Tokens.Ink.inkTertiary.color)
                .padding(.top, Tokens.Space.lg)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.Ink.window.color)
    }

    /// Only names what this build can actually do. Video appears here only when ffmpeg shipped.
    private var kindLine: String {
        var kinds = ["images", "documents", "archives", "audio"]
        if Shell.hasFFmpeg { kinds.append("video") }
        return kinds.joined(separator: " · ")
    }
}

/// The analysing screen: files landed, the analyser is choosing the plan.
struct AnalysingState: View {
    let count: Int

    var body: some View {
        VStack(spacing: Tokens.Space.lg) {
            Spacer()
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.large)
            Text("Reading \(count) \(count == 1 ? "file" : "files")…")
                .font(Tokens.Face.heading)
                .foregroundStyle(Tokens.Ink.ink.color)
            Text("Working out what each one is and what it's carrying.")
                .font(Tokens.Face.body)
                .foregroundStyle(Tokens.Ink.inkSecondary.color)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.Ink.window.color)
    }
}

/// The app mark — the real icon, not an approximation of it. The icon is a faceted gem whose
/// brightest face is the accent's hue source; drawing a lookalike here would put a second,
/// slightly-wrong logo in the app.
///
/// `package-app.sh` copies `icon.svg` into Resources alongside the .icns. The SVG carries explicit
/// `width`/`height` as well as a viewBox — with only a viewBox it decodes to a zero-size NSImage
/// and every drawing of it comes out blank, which is why `Icon.selfCheck` asserts the size.
struct TrinketMark: View {
    var size: CGFloat = 24

    var body: some View {
        Group {
            if let image = Icon.mark {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                // Outside a bundle — a CLI self-check run — there is no icon to load. A plain
                // accent square is obviously a placeholder rather than a second logo.
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(Tokens.Ink.accent.color)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Loads the app icon once. `NSImage(contentsOf:)` on every draw would re-rasterise the SVG on
/// each layout pass.
enum Icon {
    static let mark: NSImage? = {
        if let url = Bundle.main.url(forResource: "icon", withExtension: "svg"),
           let image = NSImage(contentsOf: url), image.size.width > 0 {
            return image
        }
        // A packaged build always has the .icns even if the SVG went missing.
        let fallback = NSApp?.applicationIconImage
        return (fallback?.size.width ?? 0) > 0 ? fallback : nil
    }()

    static func selfCheck() {
        // Only meaningful inside a bundle; a CLI run has no Resources folder.
        guard let url = Bundle.main.url(forResource: "icon", withExtension: "svg") else { return }
        guard let image = NSImage(contentsOf: url) else {
            assertionFailure("icon.svg is in the bundle but does not decode")
            return
        }
        assert(image.size.width > 0 && image.size.height > 0,
               "icon.svg decodes to a zero-size image — it needs explicit width/height, not just a viewBox")
    }
}
