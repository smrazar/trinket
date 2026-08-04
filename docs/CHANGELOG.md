# Changelog

## 1.1 — 2026-08-04

Two shipped bugs found by looking at real screenshots of real batches, one dead capability made
real, and every screenshot on the public site replaced.

### Fixed

- **Never hand back a bigger file — for real this time.** Scrubbing waived the size rule entirely,
  so a 166.2 KB photo came back as **222.2 KB** for the sake of removing one metadata item. The
  guard was a veto after the encode with an exemption so broad it covered the default settings. It
  is now a *ceiling on the encode*: the target size and the original size are both limits and the
  smaller wins, and only a format change lifts it. The same file now goes 166,245 → 158,865 bytes,
  and across a 22-file batch nothing grew. `ImagePass.encodeCeiling`, BUGS #12.
- **Result tiles were grey placeholders after an archive run.** The individual results are bundled
  into the output zip and their intermediates deleted, so every tile pointed at a file that no
  longer existed. Tiles now fall back to the original, which shows the same picture. Both the grid
  tile and the detail row had it. BUGS #15.

### New

- **Open With trinket, and `open -a trinket …`.** `Info.plist` had declared `CFBundleDocumentTypes`
  since 1.0, so trinket was already listed in Finder's Open With menu — and choosing it opened an
  empty window and discarded the files, because nothing implemented `application(_:open:)`. It
  works now, which is also the first piece of the "meet the files where they are" road to v2.
  BUGS #13.
- **A multi-file open arrives whole.** macOS splits one Open With of 14 files into several
  delivery calls; each used to reset the batch, so all but the last vanished without an error.
  `FileInbox` coalesces a burst into one batch. BUGS #14.

### Site

- **Every screenshot replaced.** The 1.0 shots showed a real client's job number and project name
  and were live for a day. All four images are now built from fixtures generated for the purpose —
  see `docs/shots-README.md` — and `docs/BUGS.md` records the incident and the rule that prevents
  a third one.
- **A one-minute demo video**, `docs/img/trinket-demo.mp4`: a mixed archive opened, planned,
  renamed and run. 878 KB, metadata stripped.

### Checks

Three new assertions, each verified to fail without its fix rather than merely to pass with it:
the size ceiling under a scrub (`76905 → 192870` when reverted), the four `encodeCeiling` cases,
and the split-delivery inbox. The pre-existing never-bigger assertion passed throughout the bug's
life because its fixture was a 64 px probe run with `.keepEverything` — the one path that was
never broken.

## 1.0 — 2026-08-03

A complete rewrite. Nothing from the previous build was reused; the whole `Sources/Trinket` tree was
deleted and re-authored against the redesign in `docs/Redesign/`. The icon, the palette values, the
build pipeline and the hard-won platform facts carried over — no code did.

### The idea

**The app proposes a plan.** Files land, the analyser reads them, and the left sidebar *is* the
proposal — an ordered path with every decision pre-answered. Change what you like, press one button.

### New

- **A plan the queue actually executes.** The runner walks a `Blueprint` — the stage graph the
  analyser chose, per file kind, in parallel lanes converging on one bundle. The previous build ran
  a single flat settings object over everything.
- **Reduce and Convert are one stage with two faces.** Same format → *Reduce*, owning quality,
  longest edge and target size. Different format → *Convert*, gaining a format picker with the same
  controls nested inside. One stage, because the engine does one ImageIO pass.
- **Scrub is a guarantee, not a stage** — four levels, with a "what was found" table showing exactly
  what a file carries *before* anything is removed, including the embedded thumbnail of the
  uncropped original shown beside the version being shared.
- **Mixed drops get per-kind lanes** rather than one control set covering everything.
- **Video.** The bundled ffmpeg is finally called: H.264, HEVC and VP9/WebM, with metadata stripped.
  Measured 230 MB → 132.3 MB (43%) and 75.4 MB → 4.4 MB (94%) on real clips.
- **Shrink what is inside an archive.** A dropped zip is opened, its contents re-encoded, and it is
  repacked — the answer to "I zipped my photos and it got bigger".
- **Three columns**: plan sidebar, file list, log panel. Both sidebars drag to resize between fixed
  bounds; double-clicking a divider resets it. Below 1000pt they fold away and the plan survives as
  a breadcrumb strip, so guidance is never lost.
- **Output beside the original**, as an alternative to one collecting folder.
- **"Save as my defaults"** in the plan sidebar: whatever you changed for this batch becomes the
  starting point for the next.
- **A real end-to-end check.** `--self-check` runs the unit suite *and* a pipeline suite that pushes
  real files through analyse → plan → run and asserts on the bytes that land. `package-app.sh` runs
  it, so a failing check fails the build.

### Fixed

Full root-cause write-ups in `docs/BUGS.md`. The ones worth naming here:

- **A zip dropped alongside other files was never opened**, so it came back unchanged at full size —
  the analyser only unpacked an archive when it was the single dropped item.
- **Video inside an archive passed through at full size**, gated by an images-only rule inherited
  from an engine that no longer exists.
- **The embedded-thumbnail detector was wrong for every file.** ImageIO renders a thumbnail on
  request even when told not to, so the obvious check always answers yes. Replaced with a real EXIF
  IFD1 scan.
- **A PDF's scrub was silently cancelled** when the rewrite came out larger and the original file
  was copied back. A size optimisation must never cancel a stated guarantee.
- **Files that passed through were dropped out of the repacked archive** — a row was marked amber
  without the file being copied.
- **Unchanged images were renamed `.jpg` → `.jpeg`.**
- **Status colours were unreadable as text.** The contract's amber measures 2.2:1 on white; this app
  only ever uses it as words.

### Design

- The palette is the shared design language's, unchanged: accent authored in OKLCH at hue 245.6 —
  the icon's brightest gem face — rendered at L = 0.550 for 4.64:1 against white. The redesign
  contract's own `#00a1fe` measures 2.79:1 and is used for the logo only.
- Every control is drawn from the palette. No system accent anywhere, and no stock focus ring.
- Every SF Symbol is named once in `Symbols.swift` and asserted to resolve at runtime — a misspelled
  symbol renders nothing at all rather than failing to build.
- The log is a flat sidebar, no frost: a blurred backdrop behind 12px monospace costs legibility.

### Also in this version

- **Batch renaming**, three modes modelled on PowerRename and the Finder's own: find & replace
  (regular expressions, case sensitivity, match-all, and a name/extension target), add text before
  or after, and a token template (`{name}`, `{n}`, `{date}`, `{w}×{h}`, `{parent}`…). Every mode
  shows a live **Original → Renamed** table built by the same code the run uses, so the preview
  cannot drift from what is written. Off by default.
- **Three view modes** for the file list: compact, two-line detail with thumbnails, and a
  thumbnail grid.
- **A toolbar worth having**: add, run/stop, clear, select all, the four selection actions, the
  view switcher, log, settings.
- **The plan sidebar no longer hides**, and shows with nothing dropped — it holds every control, so
  hiding it left a window that could only do what it was already going to do. Empty, it shows the
  settings the next drop will use.
- **Compare works for every kind.** Video and PDF get a poster frame each side; everything,
  archives included, gets a *What changed* table — size, name, format, dimensions, metadata count.

### Known gaps

Rows do not show progress mid-file, the floating result card is not built, and several screens are
written but have never been looked at. All listed in `docs/TODO.md` and `docs/STATUS.md`.
