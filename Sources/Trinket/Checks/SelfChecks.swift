import Foundation

/// Every non-trivial decision in the app leaves one runnable check behind. `trinket --self-check`
/// runs the lot; a debug build runs them at launch. They assert *why*, not just *what*, so a
/// later change that quietly reverses a decision fails with the reason attached.
enum SelfChecks {
    static func runAll() {
        Tokens.selfCheck()
        Bytes.selfCheck()
        Shell.selfCheck()
        Marker.selfCheck()
        Identify.selfCheck()
        Formats.selfCheck()

        Blueprint.selfCheck()
        Planner.selfCheck()
        Estimate.selfCheck()
        MetadataPass.selfCheck()
        ImagePass.selfCheck()
        DocumentPass.selfCheck()
        ArchivePass.selfCheck()
        MediaPass.selfCheck()
        Analyser.selfCheck()
        ThumbnailExtractor.selfCheck()
        Icon.selfCheck()
        Symbols.selfCheck()
        Renaming.selfCheck()

    }
}
