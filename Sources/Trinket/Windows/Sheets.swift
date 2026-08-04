import SwiftUI
import AppKit
import MapKit
import QuickLookThumbnailing

/// The metadata inspector. **A scrub nobody can verify is just a promise** — this shows exactly
/// what a file carries *before* anything is removed, with the value itself where showing it is
/// the point: the coordinates on a map, the camera serial, and the embedded thumbnail of the
/// uncropped original beside the version being shared.
struct MetadataSheet: View {
    let item: Item
    let level: ScrubLevel
    let onClose: () -> Void

    var body: some View {
        SheetFrame(title: "What \(item.name) is carrying", width: 700, height: 640, onClose: onClose) {
            VStack(alignment: .leading, spacing: Tokens.Space.lg) {
                if item.findings.isEmpty {
                    Text("Nothing found. This file carries no metadata trinket recognises.")
                        .font(Tokens.Face.body)
                        .foregroundStyle(Tokens.Ink.inkSecondary.color)
                } else {
                    FindingsTable(findings: item.findings.map {
                        MetadataFinding(category: $0.category, fileCount: 1, sample: $0.sample)
                    }, level: level, showCounts: false)

                    if let coordinate = coordinate {
                        VStack(alignment: .leading, spacing: Tokens.Space.sm) {
                            GroupHeading(text: "Where this was taken")
                            MapSnapshot(coordinate: coordinate)
                        }
                    }

                    if item.findings.contains(where: { $0.category == .embeddedThumbnail }) {
                        ThumbnailComparison(url: item.url)
                    }
                }
            }
        }
    }

    /// Parsed back out of the sample the analyser recorded, so the map needs no second read.
    private var coordinate: CLLocationCoordinate2D? {
        guard let sample = item.findings.first(where: { $0.category == .location })?.sample else { return nil }
        let parts = sample.split(separator: ",")
        guard parts.count == 2 else { return nil }
        func degrees(_ text: Substring) -> Double? {
            let cleaned = text.trimmingCharacters(in: .whitespaces)
            let value = Double(cleaned.filter { $0.isNumber || $0 == "." || $0 == "-" })
            guard let value else { return nil }
            // The reference letter carries the sign; a GPS block stores magnitudes.
            return cleaned.hasSuffix("S") || cleaned.hasSuffix("W") ? -value : value
        }
        guard let latitude = degrees(parts[0]), let longitude = degrees(parts[1]) else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// A still image of where the photo was taken.
///
/// A live `Map` cannot be used here. Inside a `ScrollView` it swallows the scroll gesture — even
/// with `.allowsHitTesting(false)` — so everything below it becomes unreachable and the sheet
/// silently clips. An image has no gestures to swallow, renders faster, and this map is only ever
/// looked at, never panned.
struct MapSnapshot: View {
    let coordinate: CLLocationCoordinate2D
    var height: CGFloat = 150

    @State private var image: NSImage?

    var body: some View {
        // The image lives in an `overlay`, not in the layout. A `resizable`+`scaledToFill` image
        // reports its own intrinsic width, which pushed the whole sheet wider than its frame and
        // clipped the text either side. An overlay is measured by its host, so it cannot.
        Rectangle()
            .fill(Tokens.Ink.chip.color)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .overlay {
                if image != nil {
                    Circle()
                        .fill(Tokens.Ink.red.color)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                        .shadow(color: .black.opacity(0.35), radius: 2)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
        .task(id: "\(coordinate.latitude),\(coordinate.longitude)") { await render() }
    }

    private func render() async {
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: coordinate,
                                            span: MKCoordinateSpan(latitudeDelta: 0.03,
                                                                   longitudeDelta: 0.03))
        options.size = CGSize(width: 560, height: height)
        options.showsBuildings = true
        let snapshotter = MKMapSnapshotter(options: options)
        image = try? await snapshotter.start().image
    }
}

/// The uncropped original beside what is actually being shared. This is the single most
/// persuasive thing the app can show: the thumbnail is a *different picture* from the one on
/// screen, and it travels with every copy of the file.
struct ThumbnailComparison: View {
    let url: URL

    @State private var embedded: NSImage?
    @State private var full: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.sm) {
            GroupHeading(text: "The thumbnail hiding inside")
            Text("A stored copy of the frame before it was cropped. It travels with the file.")
                .font(Tokens.Face.body)
                .foregroundStyle(Tokens.Ink.inkSecondary.color)

            HStack(spacing: Tokens.Space.lg) {
                labelled("What you see", image: full)
                labelled("What it carries", image: embedded)
            }
        }
        .task { load() }
    }

    private func labelled(_ title: String, image: NSImage?) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                        .fill(Tokens.Ink.chip.color)
                        .overlay(Text("—").foregroundStyle(Tokens.Ink.inkTertiary.color))
                }
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous))
            Text(title)
                .font(Tokens.Face.body)
                .foregroundStyle(Tokens.Ink.inkSecondary.color)
        }
    }

    private func load() {
        full = NSImage(contentsOf: url)
        embedded = ThumbnailExtractor.embeddedThumbnail(in: url)
    }
}

/// The batch-wide "what was found" table, opened from the scrub card in the sidebar.
struct ScrubReportSheet: View {
    let report: ScrubReport
    let level: ScrubLevel
    let onClose: () -> Void

    var body: some View {
        SheetFrame(title: "What was found", width: 700, height: 600, onClose: onClose) {
            VStack(alignment: .leading, spacing: Tokens.Space.lg) {
                Text("Across \(report.filesScanned) \(report.filesScanned == 1 ? "file" : "files"). "
                     + "Everything marked REMOVE goes when the plan runs.")
                    .font(Tokens.Face.body)
                    .foregroundStyle(Tokens.Ink.inkSecondary.color)

                if report.isEmpty {
                    Text("Nothing found.")
                        .font(Tokens.Face.body)
                        .foregroundStyle(Tokens.Ink.inkSecondary.color)
                } else {
                    FindingsTable(findings: report.ordered, level: level, showCounts: true)
                }
            }
        }
    }
}

/// The table itself: a severity dot, the category, how many files, and REMOVE or KEEP under the
/// level in force.
struct FindingsTable: View {
    let findings: [MetadataFinding]
    let level: ScrubLevel
    let showCounts: Bool

    var body: some View {
        VStack(spacing: 0) {
            ForEach(findings) { finding in
                HStack(spacing: Tokens.Space.md) {
                    Circle()
                        .fill(dot(finding.category.severity))
                        .frame(width: 7, height: 7)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(finding.category.title)
                            .font(Tokens.Face.mono)
                            .foregroundStyle(Tokens.Ink.ink.color)
                        if let sample = finding.sample {
                            Text(sample)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Tokens.Ink.inkTertiary.color)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: Tokens.Space.md)

                    if showCounts {
                        Text("\(finding.fileCount) \(finding.fileCount == 1 ? "file" : "files")")
                            .font(Tokens.Face.mono)
                            .foregroundStyle(Tokens.Ink.inkSecondary.color)
                            .fixedSize()
                    }

                    StatusTag(text: level.removes(finding.category) ? "REMOVE" : "KEEP",
                              tone: level.removes(finding.category) ? .red : .quiet)
                }
                .padding(.vertical, Tokens.Space.sm)
                Hairline()
            }
        }
    }

    private func dot(_ severity: MetadataCategory.Severity) -> Color {
        switch severity {
        case .high:   return Tokens.Ink.red.color
        case .medium: return Tokens.Ink.amber.color
        case .low:    return Tokens.Ink.inkTertiary.color
        }
    }
}

/// Before / after, as a slider over the image or side by side.
struct CompareSheet: View {
    let item: Item
    let onClose: () -> Void

    enum Mode: Hashable { case slider, sideBySide }

    @State private var mode: Mode = .slider
    @State private var position: Double = 0.5
    @State private var before: NSImage?
    @State private var after: NSImage?

    var body: some View {
        SheetFrame(title: item.name, width: 900, height: 700, onClose: onClose) {
            VStack(alignment: .leading, spacing: Tokens.Space.lg) {
                // The slider only means something when both sides are pictures. A video, a PDF or
                // a zip has no "before image" to wipe between, so the control is absent rather
                // than present and inert — and those kinds get a side-by-side of the *facts*
                // instead, which is the comparison that actually applies to them.
                if canShowPictures {
                    PaletteSegmented(options: [(Mode.slider, "Slider"), (Mode.sideBySide, "Side by side")],
                                     selection: $mode)
                        .frame(width: 240)

                    if let before, let after {
                        if mode == .slider {
                            SliderCompare(before: before, after: after, position: $position)
                                .frame(height: 420)
                        } else {
                            HStack(spacing: Tokens.Space.md) {
                                Image(nsImage: before).resizable().aspectRatio(contentMode: .fit)
                                Image(nsImage: after).resizable().aspectRatio(contentMode: .fit)
                            }
                            .frame(height: 420)
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity).frame(height: 420)
                    }
                } else {
                    previews
                }

                FactComparison(item: item)
            }
        }
        .task { await load() }
    }

    /// A poster frame each side, for the kinds that have one. A video's first frame is a fair
    /// visual comparison; a PDF's first page likewise. A zip has neither, and gets the icon.
    private var previews: some View {
        HStack(alignment: .top, spacing: Tokens.Space.lg) {
            posterColumn("Original", image: before, url: item.url)
            posterColumn("Result", image: after, url: item.outputURL)
        }
    }

    private func posterColumn(_ title: String, image: NSImage?, url: URL?) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.sm) {
            GroupHeading(text: title)
            Rectangle()
                .fill(Tokens.Ink.chip.color)
                .frame(height: 300)
                .frame(maxWidth: .infinity)
                .overlay {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFit().padding(Tokens.Space.sm)
                    } else {
                        Image(systemName: Symbols.forKind(item.kind))
                            .font(.system(size: 34))
                            .foregroundStyle(Tokens.Ink.inkTertiary.color)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
            if let url {
                Text(url.lastPathComponent)
                    .font(Tokens.Face.mono)
                    .foregroundStyle(Tokens.Ink.inkTertiary.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    /// True only when both sides really are still images. Everything else compares by facts.
    private var canShowPictures: Bool { item.kind == .image }

    private func load() async {
        before = await Self.poster(for: item.url, kind: item.kind)
        if let output = item.outputURL {
            after = await Self.poster(for: output, kind: item.kind)
        }
    }

    /// One representative frame for any kind: the image itself, a video's first frame, a PDF's
    /// first page. `QLThumbnailGenerator` handles all three, so there is no per-kind decoder here.
    private static func poster(for url: URL, kind: Kind) async -> NSImage? {
        if kind == .image { return NSImage(contentsOf: url) }
        guard kind == .video || kind == .document else { return nil }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 640, height: 640),
            scale: 2, representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request) else { return nil }
        return NSImage(cgImage: representation.cgImage, size: representation.contentRect.size)
    }

}

/// Before and after as **facts**, for every kind. A video, a PDF or an archive cannot be wiped
/// between with a slider, but "230 MB became 132.3 MB, H.264, GPS removed" is exactly the
/// comparison that matters for them — and it is worth showing for images too.
struct FactComparison: View {
    let item: Item

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.sm) {
            GroupHeading(text: "What changed")
            VStack(spacing: 0) {
                ForEach(rows, id: \.label) { row in
                    HStack(spacing: Tokens.Space.md) {
                        Text(row.label)
                            .font(Tokens.Face.body)
                            .foregroundStyle(Tokens.Ink.inkSecondary.color)
                            .frame(width: 110, alignment: .leading)
                        Text(row.before)
                            .font(Tokens.Face.mono)
                            .foregroundStyle(Tokens.Ink.inkSecondary.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: Symbols.rightArrow)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Tokens.Ink.inkTertiary.color)
                        Text(row.after)
                            .font(row.emphasised ? Tokens.Face.monoStrong : Tokens.Face.mono)
                            .foregroundStyle(row.emphasised ? Tokens.Ink.accent.color : Tokens.Ink.ink.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, Tokens.Space.sm)
                    Hairline()
                }
            }

            if let saving = item.savings {
                HStack(spacing: Tokens.Space.sm) {
                    SavingsPill(percent: saving)
                    Text("smaller — \(Bytes.format(item.originalSize - item.outputSize)) saved")
                        .font(Tokens.Face.body)
                        .foregroundStyle(Tokens.Ink.inkSecondary.color)
                }
                .padding(.top, Tokens.Space.xs)
            }
        }
    }

    private struct Row { let label: String, before: String, after: String; let emphasised: Bool }

    private var rows: [Row] {
        var rows: [Row] = [
            Row(label: "Size",
                before: Bytes.format(item.originalSize),
                after: Bytes.format(item.outputSize > 0 ? item.outputSize : item.originalSize),
                emphasised: item.savings != nil),
            Row(label: "Name",
                before: item.url.lastPathComponent,
                after: item.outputURL?.lastPathComponent ?? item.url.lastPathComponent,
                emphasised: item.outputURL.map { $0.lastPathComponent != item.url.lastPathComponent } ?? false),
            Row(label: "Format",
                before: item.url.pathExtension.uppercased(),
                after: (item.outputURL?.pathExtension ?? item.url.pathExtension).uppercased(),
                emphasised: item.outputURL.map { $0.pathExtension != item.url.pathExtension } ?? false),
        ]

        // Pixel dimensions, when the kind has any and the resize actually fired.
        if item.kind == .image, let output = item.outputURL {
            let from = ImagePass.pixelSize(of: item.url)
            let to = ImagePass.pixelSize(of: output)
            if from.width > 0, to.width > 0 {
                rows.append(Row(label: "Dimensions",
                                before: "\(from.width) × \(from.height)",
                                after: "\(to.width) × \(to.height)",
                                emphasised: from.width != to.width))
            }
        }

        // The point of the app: what the file was carrying, and what it carries now.
        if !item.findings.isEmpty {
            let remaining = item.outputURL.map { MetadataPass.inspect($0, kind: item.kind).count } ?? item.findings.count
            rows.append(Row(label: "Metadata",
                            before: "\(item.findings.count) \(item.findings.count == 1 ? "item" : "items")",
                            after: remaining == 0 ? "none" : "\(remaining) \(remaining == 1 ? "item" : "items")",
                            emphasised: remaining < item.findings.count))
        }
        return rows
    }
}

/// The slider handle over the image.
struct SliderCompare: View {
    let before: NSImage
    let after: NSImage
    @Binding var position: Double

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Image(nsImage: after)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: width, height: geometry.size.height)

                Image(nsImage: before)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: width, height: geometry.size.height)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: width * position)
                    }

                Rectangle()
                    .fill(.white)
                    .frame(width: 2)
                    .shadow(color: .black.opacity(0.3), radius: 2)
                    .overlay(
                        Circle()
                            .fill(.white)
                            .frame(width: 26, height: 26)
                            .shadow(color: .black.opacity(0.25), radius: 3)
                            .overlay(
                                Image(systemName: Symbols.dragHorizontal)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Tokens.Ink.ink.color)
                            )
                    )
                    .offset(x: width * position - 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { position = ($0.location.x / width).clamped(0, 1) }
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
    }
}

// MARK: - Frame

/// One frame for every sheet, so they cannot drift apart.
struct SheetFrame<Content: View>: View {
    let title: String
    var width: CGFloat = 620
    var height: CGFloat = 520
    let onClose: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(Tokens.Face.heading)
                    .foregroundStyle(Tokens.Ink.ink.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                ToolbarButton(icon: Symbols.close, help: "Close", action: onClose)
            }
            .padding(.horizontal, Tokens.Space.xl)
            .padding(.vertical, Tokens.Space.lg)
            Hairline()

            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Tokens.Space.panel)
            }
        }
        // The height must be **definite**, not a maximum. With any flexible height the ScrollView
        // is proposed an unbounded one, lays its content out at full height, and the sheet then
        // clips whatever does not fit — so the content below the fold is unreachable and the
        // scroll gesture does nothing. Only a definite height gives the ScrollView something to
        // scroll *inside*. Cost twice: once with `.infinity`, once with `maxHeight`.
        //
        // The default suits a form. A comparison needs far more — it has two pictures and a table
        // to fit — so each sheet passes its own size rather than everything living in one box that
        // fits none of them.
        .frame(width: width, height: height)
        .background(Tokens.Ink.window.color)
    }
}
