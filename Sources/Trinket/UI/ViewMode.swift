import SwiftUI
import QuickLookThumbnailing

/// How the middle panel draws its files.
///
/// Three, because they answer different questions: *how many* (compact), *what exactly* (detail),
/// and *which one* (thumbnails — the only view that answers "is this the right photo?").
enum ViewMode: String, Codable, CaseIterable, Identifiable {
    case compact, detail, thumbnails

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact:    return "List"
        case .detail:     return "Details"
        case .thumbnails: return "Thumbnails"
        }
    }

    var icon: String {
        switch self {
        case .compact:    return Symbols.viewCompact
        case .detail:     return Symbols.viewDetail
        case .thumbnails: return Symbols.viewGrid
        }
    }
}

/// Renders one file's thumbnail, loaded once and cached for the session.
///
/// `QLThumbnailGenerator` covers every kind macOS can preview — photo, PDF, video, even a zip's
/// icon — so there is no per-kind decoder here and nothing to add when a new format is supported.
struct FileThumbnail: View {
    let url: URL
    /// Shown when `url` cannot produce one. After an archive run the individual results are
    /// bundled and their intermediates deleted, so every `outputURL` points at a file that is no
    /// longer there and every tile fell back to a grey placeholder icon — a grid of identical
    /// placeholders, in the one view whose entire job is answering "which file is this?".
    /// The original is still on disk and shows the same picture.
    var fallback: URL?
    let kind: Kind
    var size: CGFloat = 96

    @State private var image: NSImage?

    var body: some View {
        RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
            .fill(Tokens.Ink.chip.color)
            .frame(width: size, height: size)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: Symbols.forKind(kind))
                        .font(.system(size: size * 0.3))
                        .foregroundStyle(Tokens.Ink.inkTertiary.color)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous))
            .task(id: url) { await load() }
    }

    private func load() async {
        if let cached = ThumbnailCache.shared.image(for: url) {
            image = cached
            return
        }
        if let rendered = await render(url) {
            ThumbnailCache.shared.store(rendered, for: url)
            image = rendered
            return
        }
        // The result is gone — bundled into an archive, or moved. The original still shows the
        // same picture, which is the whole question a tile answers.
        guard let fallback, fallback != url else { return }
        if let cached = ThumbnailCache.shared.image(for: fallback) {
            image = cached
            return
        }
        guard let rendered = await render(fallback) else { return }
        ThumbnailCache.shared.store(rendered, for: fallback)
        image = rendered
    }

    private func render(_ target: URL) async -> NSImage? {
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        let request = QLThumbnailGenerator.Request(
            fileAt: target,
            size: CGSize(width: size * 2, height: size * 2),
            scale: 2,
            representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request) else { return nil }
        return NSImage(cgImage: representation.cgImage, size: representation.contentRect.size)
    }
}

/// One file as a tile. The thumbnail answers the question this view exists for — *which one is
/// it?* — so the name and numbers sit under it rather than competing with it.
struct FileTile: View {
    @ObservedObject var item: Item
    let isSelected: Bool

    /// A thumbnail exists to answer "is this the right file?", and 108pt was too small to answer
    /// it for a photograph — the whole point of the view was being lost to save space that the
    /// grid had anyway.
    static let thumbnail: CGFloat = 168
    static let tile: CGFloat = thumbnail + Tokens.Space.xxl

    var body: some View {
        VStack(spacing: Tokens.Space.sm) {
            ZStack(alignment: .bottomTrailing) {
                FileThumbnail(url: item.outputURL ?? item.url, fallback: item.url,
                              kind: item.kind, size: Self.thumbnail)
                // The state rides in the corner of the thumbnail. A tile has no room for a row
                // of tags, and the one thing worth knowing at a glance is whether it is done.
                //
                // Every badge sits on a **solid** fill. A tinted one was unreadable: it landed on
                // whatever the photo happened to be, so "79%" over a bright mosaic vanished.
                switch item.state {
                case .done:
                    if let saving = item.savings { TileBadge(text: "\(saving)%", tone: .accent) }
                case .running(let fraction):
                    TileBadge(text: "\(Int((fraction * 100).rounded()))%", tone: .accent)
                case .failed:
                    TileBadge(text: "Failed", tone: .red)
                case .passedThrough, .skipped:
                    TileBadge(text: "Unchanged", tone: .amber)
                case .queued:
                    EmptyView()
                }
            }

            Text(item.name)
                .font(Tokens.Face.body)
                .foregroundStyle(Tokens.Ink.ink.color)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(height: 32, alignment: .top)

            // Before a run this is an *estimate*, and an estimate printed under a real thumbnail
            // reads as a fact. Show what the file actually is until there is a measured number.
            Text(Bytes.format(item.state.isTerminal ? item.shownSize : item.originalSize))
                .font(Tokens.Face.mono)
                .foregroundStyle(Tokens.Ink.inkTertiary.color)
        }
        .padding(Tokens.Space.sm)
        .frame(width: Self.tile)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                .fill(isSelected ? Tokens.Ink.accentSoft.color : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
        .animation(Tokens.Motion.quick, value: isSelected)
    }
}

/// A badge in the corner of a tile. **Solid**, never tinted: it lands on whatever the picture
/// happens to be, and a translucent badge over a bright photo is invisible exactly when the photo
/// is most interesting.
struct TileBadge: View {
    enum Tone { case accent, amber, red }

    let text: String
    var tone: Tone = .accent

    var body: some View {
        Text(text)
            .font(Tokens.Face.monoStrong)
            .foregroundStyle(Tokens.Ink.onAccent.color)
            .padding(.horizontal, Tokens.Space.sm)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(fill)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            )
            .padding(Tokens.Space.sm)
    }

    private var fill: Color {
        switch tone {
        case .accent: return Tokens.Ink.accent.color
        case .amber:  return Tokens.Ink.amber.color
        case .red:    return Tokens.Ink.red.color
        }
    }
}

/// Thumbnails are expensive enough that scrolling a 400-photo drop would regenerate them
/// constantly without this. Bounded, because a batch can be arbitrarily large.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private var storage: [URL: NSImage] = [:]
    private var order: [URL] = []
    private let ceiling = 400

    func image(for url: URL) -> NSImage? { storage[url] }

    func store(_ image: NSImage, for url: URL) {
        if storage[url] == nil { order.append(url) }
        storage[url] = image
        while order.count > ceiling {
            storage.removeValue(forKey: order.removeFirst())
        }
    }

    func clear() {
        storage = [:]
        order = []
    }
}
