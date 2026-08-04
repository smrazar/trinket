# trinket — architecture

The map of the rewrite. Read this before changing anything; it explains *why* each piece is shaped
the way it is, which is the part that gets lost between sessions and re-litigated.

## The one idea

**The app proposes a plan.** Files land, the analyser reads them, and the left sidebar *is* the
proposal: an ordered path with every decision pre-answered. The user changes what they like and
presses one button. Guidance is visible, never gated — the common case is drop → Run → done.

Everything below serves that. The single biggest structural difference from the previous build is
that the queue executes a **`Blueprint`** (a stage graph the analyser chose) rather than one flat
settings object applied uniformly to every file.

## Layers

```
Core/      Tokens · Bytes · Logbook · Shell · Defaults
Model/     Kind · Formats · Scrub · Blueprint · Planner · Estimate · Item
Engines/   Analyser · ImagePass · MetadataPass · ThumbnailExtractor
           DocumentPass · ArchivePass · MediaPass · Runner
UI/        Tokens-drawn controls · PlanSidebar · FileList · LogPane
           MainWindow · EmptyState · Symbols · ResizableDivider
Windows/   SettingsWindow · AboutWindow · Sheets
Checks/    SelfChecks (synchronous) · PipelineCheck (end-to-end, async)
```

The dependency direction is strictly downward. **`Model/` never imports AppKit or touches the
filesystem**, which is what lets `Planner`, `Blueprint` and `Estimate` run their assertions without
an app being present.

## The plan model

`Blueprint` is what the analyser proposes and the runner executes.

- **`Lane`** — one per file *kind* actually present. A mixed drop gets several, running in
  parallel, converging on one Bundle. Lane order follows `Kind.allCases` so the sidebar never
  reshuffles when a file is added.
- **`ShrinkStage` is one stage with two faces.** When the target format equals the source it is
  **Reduce** and owns quality / longest edge / target size. When the format changes it becomes
  **Convert** and gains a format picker with the same reduction controls nested inside. The face is
  *derived* from the target, never stored. This matters: the image engine does **one ImageIO pass**
  that resizes, re-encodes and scrubs together, and two separate UI stages would imply two passes —
  which would mean decoding and re-encoding twice, losing quality twice.
- **Scrub is not a stage.** It is a guarantee attached to the whole plan, shown in the sidebar
  footer with its four levels and a "what was found" disclosure. A scrub nobody can verify is just
  a promise, so the finding half runs *before* the user presses Run.
- **Stages that do not apply are absent, not disabled.** No video encoder in this build → there is
  no video stage and a caveat says so in words.

`Planner.propose(PlanInput) -> Blueprint` is pure: same input, same output, no I/O. That purity is
the reason ~40 planner assertions run in a plain CLI invocation.

## The engines

| Pass | Backend | Notes |
|---|---|---|
| `ImagePass` | ImageIO | One pass: decode-at-target-size, resize, re-encode, scrub. Binary-searches quality when a target size is set. |
| `MetadataPass` | ImageIO / PDFKit / AVFoundation | Finds what a file carries; builds the surviving properties dictionary. |
| `ThumbnailExtractor` | raw bytes | Pulls the real embedded thumbnail out of a JPEG's EXIF IFD1. |
| `DocumentPass` | PDFKit + CoreGraphics | Rebuilds a PDF page by page, which is also what drops its revision history. |
| `ArchivePass` | `/usr/bin/tar` (bsdtar/libarchive), `/usr/bin/zip` | Read zip/tar/7z/xz/cpio with no dependency. |
| `MediaPass` | `afconvert`, bundled `ffmpeg` | `afconvert` for everything Core Audio can write; ffmpeg for MP3/Opus/Vorbis and all video. |

### The scrub builds, it never filters

`MetadataPass.imageProperties(keeping:from:…)` constructs a **fresh** dictionary of what survives,
rather than deleting known keys from the source. Deleting means every block nobody enumerated —
maker notes, XMP packets, a vendor's private IFD — rides along untouched. Building means only named
things survive. The self-check asserts an unenumerated maker note does not make it through.

## The runner

`Runner` executes the Blueprint. Per lane, concurrently; everything converges on Bundle.

- **Destinations are resolved up front**, on the main actor where the items live, into a
  `[UUID: URL]` map. The lane tasks receive plain URLs — no closure reading main-actor state.
- **An archive in, an archive out.** Each opened container gets its own staging folder, repacked at
  the end. Files dropped loose are written straight out and never swept into somebody else's zip.
- **Every pass-through still copies the file.** Marking a row amber without copying is exactly how
  an entry disappears out of a repacked archive; that bug shipped once and is now pinned by a check.
- **Being inside an archive changes nothing about what can be done to a file.** Entries are
  unpacked to disk first, so they go through the same passes a loose file does.

## Checks

Two suites, both run by `trinket --self-check`, which `package-app.sh` invokes — **a failing check
fails the build**, so a check that stops being true cannot ship.

- **`SelfChecks.runAll()`** — synchronous, per-unit. Colour contrast, byte formatting, kind
  detection, the plan model, the planner, estimates, and each engine against probe files it
  synthesises itself (no fixtures on disk).
- **`PipelineCheck.run()`** — end-to-end, `@MainActor`. Real files through analyse → plan → run,
  asserting on the bytes that actually land: sizes fell, GPS gone, thumbnail gone, archive entries
  all present, loose files still loose.

Assertions state **why**, not just what, so a later change that reverses a decision fails with the
reason attached.

## Platform traps, each paid for once

- **ImageIO cannot tell you whether a thumbnail is embedded.** `CGImageSourceCreateThumbnailAtIndex`
  renders one from the full image and returns it even with `…FromImageAlways` and
  `…FromImageIfAbsent` both false — so the obvious check answers "yes" for every file ever written.
  Measured, not assumed. `MetadataPass.hasEmbeddedThumbnail` parses the APP1/Exif segment and looks
  for IFD1 tag `0x0201` instead.
- **PDFKit re-injects `Producer`, `CreationDate` and `ModDate` on every write** and offers no way to
  suppress them. "Nothing but pixels" therefore cannot fully deliver on a PDF; the Settings copy
  says so rather than claiming otherwise. A self-check asserts this is *still* true, so if the OS
  ever stops doing it the copy gets updated instead of quietly lying in the other direction.
- **A size optimisation must never cancel the scrub.** When a PDF rewrite comes out bigger, the
  fallback keeps the original *pages* with scrubbed attributes — copying the original *file* would
  restore every piece of metadata the user asked to remove.
- **`PDFPage(image:)` takes the page box from `NSImage.size`, in points.** A 2× render therefore
  doubles the paper size, and `setBounds` then crops rather than scales. Render at 2× for pixels,
  declare the point size of the original.
- **`NSImage.lockFocus()` allocates at the display's scale**, so the same code produces different
  output on different monitors. Never for deterministic rendering — use a `CGContext` told its size.
- **A SwiftUI `Menu` is only clickable where its label is.** No outer `.frame`, `.contentShape` or
  stretched `Color.clear` extends it. `PaletteMenu` is a `Button` driving a real `NSMenu`.
- **`NSMenuItem.target` is weak**, so the target must be kept alive while the menu is up.
  `popUpContextMenu` blocks, so a local holds it — but only because that call is synchronous.
- **`UserDefaults(suiteName:)` returns nil when the suite is the app's own bundle id**, so a check
  on it passes for a bare binary and fails inside the app. Use `.standard`.
- **Draining a subprocess's pipes after it exits deadlocks** as soon as either fills its 64 KB
  buffer, which ffmpeg's progress output does within a second. `Shell.run` drains both concurrently.
- **`Text` inside an `HStack` cannot wrap between children.** The 28pt payoff headline ran off a
  narrow window; `Text + Text` keeps per-run colour *and* wraps.
- **Blocking the main thread to await `@MainActor` work deadlocks.** The `--self-check` path hands
  the run to the main actor and pumps the run loop instead.

## Colour

The palette is the shared design language used across the family — accent authored in OKLCH, grey
ramp authored as hex. The accent is the icon's brightest gem face `#00a1fe` converted to OKLCH hue
**245.6**, rendered at **L = 0.550** (`#0075D7`).

**The documented divergence:** the shared light accent is `oklch(0.580 0.190 h)` → `#007EE2`, and
white on it is **4.13:1**, under WCAG AA's 4.5 for 13pt semibold. L = 0.550 reaches **4.64**. The
self-check asserts the *ratio*, so restoring the lighter value fails the build.

The redesign contract also names `#00a1fe` itself as the interface accent. White on it is
**2.79:1** — worse than the value the contract explicitly rejects. It is the hue source and the
logo, never a fill for text. Likewise the contract's amber `#f59e0b` (2.2:1) and green `#34c759`
are swatch colours, not text colours; both are darkened here because the only way this app uses
them is as words.
