import AppKit
import SwiftUI

/// Every SF Symbol the app draws, named once for what it *means* rather than what it looks like.
///
/// A misspelled symbol name is not a build error — `Image(systemName:)` renders nothing at all and
/// the button silently becomes a blank square. `selfCheck` asks the system to resolve every name
/// below, so a typo fails the build instead of shipping a hole in the toolbar.
enum Symbols {

    // MARK: Plan stages
    /// Opening a container.
    static let unpack = "shippingbox"
    /// Making a file smaller without changing what it is.
    static let reduce = "arrow.down.right.and.arrow.up.left"
    /// Changing the format.
    static let convert = "arrow.triangle.2.circlepath"
    /// Packing the results back into one archive.
    static let bundle = "archivebox"
    /// The scrub guarantee.
    static let scrub = "shield.lefthalf.filled"

    // MARK: Run control
    static let run = "play.fill"
    static let pause = "pause.fill"
    static let stop = "stop.fill"
    static let paused = "pause.circle"
    /// The in-progress spinner in the list header and the plan rail.
    static let working = "circle.dotted"
    static let done = "checkmark.circle.fill"
    static let tick = "checkmark"

    // MARK: Toolbar
    static let sidebarToggle = "sidebar.leading"
    static let quickLook = "eye"
    /// Before / after.
    static let compare = "rectangle.split.2x1"
    static let reveal = "folder"
    /// The log panel: lines of text in a pane, not prose — `text.alignleft` reads as a paragraph
    /// formatting control, which is what a text editor puts in its toolbar.
    static let log = "list.bullet.rectangle"
    static let settings = "gearshape"

    // MARK: Status
    /// Not yet supported · passes through · queued.
    static let notYet = "clock"
    static let failed = "exclamationmark.triangle.fill"
    static let info = "info.circle"
    /// Smart quality, which is always on.
    static let smart = "wand.and.stars"
    /// The offline promise.
    static let offline = "lock.fill"

    // MARK: Controls
    static let disclosure = "chevron.right"
    static let menuChevron = "chevron.up.chevron.down"
    static let radioOn = "largecircle.fill.circle"
    static let radioOff = "circle"
    static let close = "xmark"
    static let add = "plus"
    static let clearList = "xmark.circle"
    static let selectAll = "checklist"
    static let rename = "character.cursor.ibeam"
    static let viewCompact = "list.bullet"
    static let viewDetail = "list.dash.header.rectangle"
    static let viewGrid = "square.grid.2x2"
    static let copy = "doc.on.doc"
    static let clear = "trash"
    /// The compare slider's handle.
    static let dragHorizontal = "arrow.left.and.right"
    /// before -> after, in the comparison tables.
    static let rightArrow = "arrow.right"

    // MARK: Kinds
    static let image = "photo"
    static let document = "doc.text"
    static let archive = "shippingbox.fill"
    static let audio = "waveform"
    static let video = "film"
    static let other = "doc"
    /// A loose pile of files, as opposed to one opened container.
    static let files = "doc.on.doc.fill"
    static let containerHeader = "shippingbox.fill"

    static func forKind(_ kind: Kind) -> String {
        switch kind {
        case .image:    return image
        case .document: return document
        case .archive:  return archive
        case .audio:    return audio
        case .video:    return video
        case .other:    return other
        }
    }

    /// Every name above, so the check cannot drift from the list by someone adding one and
    /// forgetting the other.
    static let all: [String] = [
        unpack, reduce, convert, bundle, scrub,
        run, pause, stop, paused, working, done, tick,
        sidebarToggle, quickLook, compare, reveal, log, settings,
        notYet, failed, info, smart, offline,
        disclosure, menuChevron, radioOn, radioOff, close, copy, clear, dragHorizontal, rightArrow,
        add, clearList, selectAll, rename, viewCompact, viewDetail, viewGrid,
        image, document, archive, audio, video, other, files, containerHeader,
    ]

    static func selfCheck() {
        for name in all {
            assert(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                   "\"\(name)\" is not an SF Symbol on this OS — it would render as nothing at all")
        }
    }
}
