// swift-tools-version:5.10
import PackageDescription

// One target, no dependencies. Everything trinket needs is a framework already on the machine —
// ImageIO, PDFKit, Vision, AVFoundation, libarchive — apart from ffmpeg, which is vendored as a
// binary by package-app.sh rather than linked.
let package = Package(
    name: "Trinket",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "Trinket")
    ]
)
