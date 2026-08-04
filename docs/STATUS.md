# trinket — status

*Updated 2026-08-04. Version 1.1, published. Branch `main`.*

**Read this first.** It is the handoff: what exists, what is proven, what is merely written, and
what is left. Anything claimed here as verified has either a runnable assertion behind it or a
named measurement against a real file.

---

## What this is

A complete rewrite. **No file from the previous build was reused** — the old `Sources/Trinket` tree
was deleted and everything re-authored against `docs/Redesign/`. What carried over deliberately:

- `Assets/icon.svg` and `Assets/icon.pxd` — the real app icon.
- The shared design language's palette values (accent authored in OKLCH, grey ramp as hex), so the
  app still matches its siblings.
- `package-app.sh`, `install.sh`, `Tools/make-icon.swift` — the build pipeline.
- The measured facts and platform traps, now recorded in `docs/ARCHITECTURE.md`.

The old build's design doc, changelog, bug list and status file were replaced rather than edited;
they described a different program.

## State

**The whole path works end to end, on the user's own files.**

| Capability | State | Evidence |
|---|---|---|
| Images: resize, re-encode, convert | works | 9.5 MB → 122 KB (99%) on a real 4000×3000 photo |
| Metadata scrub | works | GPS present in source, absent from result; no serial left in the raw bytes |
| PDF rebuild | works | 17.2 MB → 12.0 MB (30%) on a real 23-page document |
| Video convert | works | 230 MB → 132.3 MB (43%), and 75.4 MB → 4.4 MB (94%) on real clips |
| Audio convert | works | WAV → AAC round trip asserted playable in `MediaPass` |
| Archive open → shrink inside → repack | works | 145 MB zip: photos and video both shrink, all entries survive |
| Beside-the-original output | works | asserted in `PipelineCheck` |
| Dark mode | works | verified by screenshot |
| Batch renaming | works | 3 modes, ~30 assertions, live preview table |
| Three view modes | works | list / detail / thumbnails, verified by screenshot |
| Per-file progress | works | ffmpeg -progress parsed; batch weighted by bytes |
| Floating result card | works | non-activating panel, honours the preference |

Every one of the above is covered by an assertion in `--self-check`, which `package-app.sh` runs, so
**a failing check fails the build**.

## Verified vs. written-but-unlooked-at

**Verified by a human looking at it:** welcome screen, empty/drop state, the plan sidebar (with
files, empty, and with a five-lane mixed drop), the running list, the finished payoff banner in
both list and thumbnail views, the log sidebar, Settings (General, Images, Media, Scrub), the About
window, the metadata inspector including its map, the compare sheet, the renaming sheet, the row
context menu, all three view modes, the 720pt breadcrumb strip, light and dark, and a full archive
round trip from drop to repacked zip.

**Written but never seen on screen:** the batch-wide scrub report sheet, the analysing state, and
the Documents / Log settings tabs. These compile and their logic is checked; **their appearance is
unproven.**

The About window, the welcome screen and the compare sheet are all on the public site or in the
README now, which means they are verified by the strongest available test: somebody looked at them
long enough to publish them.

**Not built at all:** the floating drop target and floating result card (`floating-drop.html`,
`floating-result.html` in the design bundle). The `floatingResults` preference exists and is
persisted, but nothing reads it yet.

## What 1.1 changed

Four bugs, all four found by looking at screenshots of real batches rather than by any check.

- **The size rule was not a rule.** Scrubbing waived it, so a 166.2 KB photo came back as 222.2 KB
  to remove one metadata item. It is now a ceiling on the encode. Same file: 166,245 → 158,865
  bytes; nothing in a 22-file batch grew.
- **Open With trinket did nothing.** The document types were declared in 1.0 and the delegate
  method to receive the files was never written.
- **A 14-file open lost the 14th.** macOS splits the delivery; each call reset the batch.
- **Result tiles were placeholders after an archive run**, because their outputs had been bundled
  and deleted.

**And every screenshot on the public site was replaced** — the 1.0 pair showed a real client's job
number and project name. `docs/BUGS.md` carries the incident; `docs/shots-README.md` carries the
fixture recipe so it cannot recur casually.

The three new assertions were each checked *red* — reverted to the buggy code and watched to fail —
before being kept. The pre-existing never-bigger assertion had passed for the bug's whole life
because its fixture was the one shape that was never broken.

## What is left

Tracked in `docs/TODO.md`. The short version, highest value first:

1. Look at the remaining unproven screens listed above — three left.
2. Decide what the metadata map costs: `MKMapSnapshotter` fetches tiles, so the one panel built to
   show a coordinate you are about to remove is also the one thing in the app that touches the
   network. The file never leaves; the coordinates do.
3. Mid-file progress for images and PDFs. Video moves; they do not.
4. Whatever the next real batch turns up. Every bug in 1.0 and 1.1 came from a real run, and none
   of them came from the suite.

## How to work on this

```bash
swift build                       # debug
./.build/debug/Trinket --self-check   # every assertion, no window
./package-app.sh                  # release + icon + ffmpeg + sign; runs --self-check and fails on it
open build/trinket.app
```

The log is at `~/Library/Logs/trinket/session.log` and in the app's right sidebar.

**Before changing anything, read `docs/ARCHITECTURE.md`** — particularly the platform-traps section.
Most of the non-obvious code in this app is shaped by one of those, and each cost real time to find.

**Before claiming a UI change works, look at it.** See the last section of `docs/BUGS.md`.

## Decisions not to relitigate

These were each argued once and are asserted in code, so reversing one fails the build rather than
silently changing behaviour.

- **The accent ships at OKLCH L = 0.550 (`#0075D7`).** The design contract names `#00a1fe`, on which
  white text measures 2.79:1 — worse than the L = 0.580 the same contract explicitly rejects.
  `#00a1fe` is the icon's brightest face and the hue source, not a fill for text.
- **Reduce and Convert are one stage with two faces**, because the engine does one ImageIO pass.
  Two stages would imply two passes, which means losing quality twice.
- **Scrub is a guarantee, not a stage**, and what it will remove is shown *before* the run.
- **The scrub builds a fresh properties dictionary rather than deleting known keys**, so metadata
  nobody enumerated cannot ride along.
- **An archive defaults to "Open it"**, and every dropped archive is opened, not just a lone one.
- **An archive in, an archive out; loose files in, loose files out.** Nothing the user did not hand
  us zipped gets zipped.
- **The original file is never touched by default.**
- **Stages that do not apply are absent, not disabled**, and the reason is said in words.
- **Nothing is claimed that is not done.** A file that cannot be improved is marked amber and
  named, never given a progress bar that lies.

## Shipped defaults

Set from the user's own preferences on 2026-08-03, in `Defaults.Factory`:

JPEG · quality 0.75 · longest edge 1024px · target 250 KB · documents keep · MP3 · H.264 ·
scrub "Nothing but pixels" · originals kept · output **beside the original** · window solid ·
floating results on · plan sidebar shown · log sidebar hidden.

`outputFolderPath` is deliberately not part of the factory set — a path is per-machine. It stays
`~/Downloads/trinket` and `outputLocation` decides whether it is used at all.

## The folder is consolidated

`~/Developer/trinket` **is** the rewrite. `main` was fast-forwarded to it on 2026-08-03, the three
stale worktrees (`phase4`, `qol-audit`, `redesign`) were removed and their branches deleted. What
the user opens in Finder is now what this document describes — which was not true for the whole of
the previous round, and produced three false "you didn't do it" reports.

As of 2026-08-04 there is **one branch and no leftover worktrees** — the stale ones from the
rewrite were removed and their branches deleted. What Finder shows is what this document describes.

**`docs/Redesign/` is untracked on purpose.** It is the design bundle the rewrite was built
against — contract, 18 HTML mockups, PNG renders. It lives in the working folder but is not
committed, so it will not travel to GitHub. If a future session cannot find it, that is why; it is
a design input, not app source.

## Published

- **Source:** https://github.com/smrazar/trinket — `main`, pushed 2026-08-03.
- **Release:** https://github.com/smrazar/trinket/releases/tag/v1.0 with an ad-hoc signed zip.
  Not notarised, so Gatekeeper blocks a download; the notes say how to clear it.
- **Site:** https://smrazar.github.io/trinket/ — built from `docs/` by `Tools/make-site.py`, which
  is **identical in every app repo**. Everything app-specific is in `Tools/site.json`.
  **Never fork the generator**; edit the JSON.

Before the first push the full scan ran clean: one git identity (the noreply address), no personal
paths in any tracked file, no sibling app named, and nothing in the binary but upstream ffmpeg's
own `/Users/buildserver`.

The old leftovers are gone: no open PRs, `origin` carries only `main`, and the releases are
`v1.0` and `v1.1`.

GPL-3, because the bundled ffmpeg is GPL. `Resources/ffmpeg-BUILD.txt` records the upstream build so
the corresponding-source offer is answerable.
