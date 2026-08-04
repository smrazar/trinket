import SwiftUI

/// The standard macOS About window, drawn from the palette rather than the stock panel.
struct AboutWindow: View {
    var body: some View {
        VStack(spacing: Tokens.Space.md) {
            TrinketMark(size: 84)
                .padding(.top, Tokens.Space.s32)

            Text("trinket")
                .font(Tokens.Face.display)
                .foregroundStyle(Tokens.Ink.ink.color)

            Text("Version \(Bundle.version) (\(Bundle.build))")
                .font(Tokens.Face.body)
                .foregroundStyle(Tokens.Ink.inkSecondary.color)

            Label("Works offline. No file ever leaves your Mac.", systemImage: Symbols.offline)
                .font(Tokens.Face.body)
                .foregroundStyle(Tokens.Ink.accent.color)
                .padding(.horizontal, Tokens.Space.md)
                .padding(.vertical, Tokens.Space.sm)
                .background(Capsule().fill(Tokens.Ink.accentTint.color))

            Text("Smaller files, a friendlier format, and nothing hiding inside them.")
                .font(Tokens.Face.body)
                .foregroundStyle(Tokens.Ink.inkSecondary.color)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Tokens.Space.panel)
                .padding(.top, Tokens.Space.sm)

            Spacer()

            HStack(spacing: Tokens.Space.sm) {
                SecondaryButton(title: "Website", fillsWidth: false) {
                    if let url = URL(string: "https://github.com/smrazar/trinket") {
                        NSWorkspace.shared.open(url)
                    }
                }
                SecondaryButton(title: "Acknowledgements", fillsWidth: false) {
                    NSWorkspace.shared.open(Bundle.licenceURL ?? URL(filePath: "/"))
                }
            }

            Text(Bundle.licenceLine)
                .font(.system(size: 11))
                .foregroundStyle(Tokens.Ink.inkTertiary.color)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Tokens.Space.xl)
                .padding(.bottom, Tokens.Space.xl)
        }
        .frame(width: 380, height: 480)
        .background(Tokens.Ink.window.color)
    }
}

/// First run. Explains the three promises, then gets out of the way — one button, never gated.
struct WelcomeWindow: View {
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TrinketMark(size: 76)
                .padding(.top, Tokens.Space.s40)

            Text("Welcome to trinket")
                .font(Tokens.Face.display)
                .foregroundStyle(Tokens.Ink.ink.color)
                .padding(.top, Tokens.Space.lg)

            Text("Drop a file. trinket proposes a plan and you press one button.")
                .font(Tokens.Face.body)
                .foregroundStyle(Tokens.Ink.inkSecondary.color)
                .padding(.top, Tokens.Space.xs)

            VStack(alignment: .leading, spacing: Tokens.Space.lg) {
                promise(Symbols.reduce, "Smaller",
                        "Photos, PDFs and archives shrink — often by half — without looking worse.")
                promise(Symbols.convert, "A friendlier format",
                        "HEIC that nobody else can open becomes a JPEG that everybody can.")
                promise(Symbols.scrub, "Safe to send",
                        "See the GPS, the camera serial and the uncropped thumbnail hiding inside — then watch them go.")
            }
            .padding(.horizontal, Tokens.Space.s32)
            .padding(.top, Tokens.Space.s32)

            Spacer()

            PrimaryButton(title: "Get started", fillsWidth: false, action: onStart)
                .fixedSize()
                .padding(.bottom, Tokens.Space.md)

            Label("Everything runs on your Mac. No file ever leaves it.", systemImage: Symbols.offline)
                .font(Tokens.Face.body)
                .foregroundStyle(Tokens.Ink.inkTertiary.color)
                .padding(.bottom, Tokens.Space.s32)
        }
        .frame(width: 520, height: 620)
        .background(Tokens.Ink.window.color)
    }

    private func promise(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Tokens.Space.lg) {
            ZStack {
                RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                    .fill(Tokens.Ink.accentTint.color)
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Tokens.Ink.accent.color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Tokens.Face.heading)
                    .foregroundStyle(Tokens.Ink.ink.color)
                Text(detail)
                    .font(Tokens.Face.body)
                    .foregroundStyle(Tokens.Ink.inkSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension Bundle {
    static var version: String {
        main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    static var build: String {
        main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    static var licenceURL: URL? {
        main.url(forResource: "LICENSE", withExtension: nil)
            ?? URL(string: "https://github.com/smrazar/trinket/blob/main/LICENSE")
    }

    /// GPL-3 because the bundled ffmpeg is GPL — a build without it would be free to be MIT, but
    /// shipping one licence that depends on which files were present at package time is worse.
    static var licenceLine: String {
        Shell.hasFFmpeg
            ? "GPL-3.0. Bundles ffmpeg, which is GPL-licensed."
            : "GPL-3.0."
    }
}
