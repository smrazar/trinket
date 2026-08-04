# trinket — design

The shipped design, and where it diverges from the mockup. The authoritative visual reference is
`docs/Redesign/` — the contract, eighteen HTML screens and their renders. **That bundle is a
mockup: it is layout and intent, not values to copy literally.** Where it and an accessibility
measurement disagree, the measurement wins, and the divergence is recorded here and asserted in
`Tokens.selfCheck()`.

## What the app is

Offline file conversion, compression and **metadata scrubbing** for macOS. Nothing leaves the Mac.

The differentiator is the scrub: it *shows* what a file is carrying — GPS, camera serial, edit
history, the embedded thumbnail of the **uncropped** original — before removing it. A scrub nobody
can verify is just a promise.

## The single idea

**The app proposes a plan.** Files land, the analyser chooses an ordered path built from four
stages — **Unpack → Reduce → Convert → Bundle** — with **Scrub** riding alongside as a guarantee
rather than a stage. The user sees the whole path at once, changes any part of it, and presses one
button.

Guidance is **visible, never gated**. The common case is drop → one button → done.

## Colour

The palette is the shared design language used across the app family, carried over unchanged: the
**accent family is authored in OKLCH**, the **grey ramp is authored as hex**. The accent hue is
**245.6** — the app icon's brightest gem face, `#00a1fe`, converted — so the icon and the interface
agree without a second blue appearing anywhere.

### Three divergences from the mockup, all for contrast

| Token | Mockup | Shipped | Why |
|---|---|---|---|
| accent | `#00a1fe` | `#0075D7` (OKLCH L 0.550) | white on `#00a1fe` is **2.79:1** — worse than the L 0.580 the contract itself rejects. Shipped value: **4.64:1** |
| amber | `#f59e0b` | `#A35F00` | `#f59e0b` is **2.2:1** on white. This colour is only ever used as *words* |
| green | `#34c759` | `#178036` | same reason; a swatch colour, not a text colour |

`#00a1fe` is the hue source and the logo. It never carries text.

### Usage

- **The accent marks actions and results ONLY** — the Run button, progress fills, the savings pill,
  the current selection, the finished payoff number. Never a label, a group heading or a kind badge.
- **Kind badges are charcoal on a recessed chip**, and hug their text rather than sitting in a fixed
  frame.
- **Never the system accent, and never a stock focus ring.** Every toggle, segmented control,
  slider, picker and number field is drawn from the palette. The stock focus ring paints in the
  system accent and reads as a blue bar across the window, so anything focusable pairs
  `.focusable()` with `.focusEffectDisabled()`.
- Status colours whisper: amber = skipped / not-yet / paused, red = failed. A finished result reads
  in **accent**, not green — green is only the small done tick.

## Typography

**One uppercase tier only:** group headings (`PLAN`, `LOG`, `OUTPUT`) at 11/600 with tracking. Field
labels are **sentence case**. When both were uppercase the sidebar had no hierarchy.

Display 28/700 (payoff number, empty-state title) · heading 17/600 (stage names, filenames) ·
body 13/400 · label 11/600 uppercase · mono 12/400 for the log **and every byte figure**, so numbers
align in a column.

## Layout

Three columns in one window: **plan sidebar · file list · log panel**. The window is symmetrical —
plan and log are mirror sidebars, each toggled from the toolbar, each draggable between bounds with
a double-click on the divider to reset.

- **720pt (minimum) — neither sidebar.** The plan survives as a horizontal **breadcrumb strip**
  above the list, so guidance is never lost, and the filename finally gets its width.
- **~1000pt — one sidebar.** The plan opens on the left; the log stays off.
- **wide — both.**

Spacing `4 · 8 · 12 · 16 · 20 · 24 · 28 · 32 · 40`. Panel padding 28, card 20, file row 14×16.
Radii: control 6, card 10, panel 14. Motion 120–160ms ease-out.

## The plan sidebar

The sidebar **is** the plan: one section per stage, in the order the analyser chose, connected by a
rail so it reads as a path rather than a list of settings.

- Each stage collapses to **a single line stating its decision** (`JPEG · 75% · 1024px · ≤ 250 KB`)
  and expands to change it. Every decision arrives pre-answered.
- **Reduce / Convert is one stage with two faces.** Format unchanged → *Reduce*, owning quality,
  longest edge and target size. Format changed → *Convert*, gaining a format picker with the same
  reduction controls nested inside. Never two stages for one image: the engine does a single
  ImageIO pass, and two stages would imply two.
- **Stages that do not apply are absent, not disabled**, and a caveat says why in words.
- **Mixed drops get per-kind lanes** running in parallel and converging on one Bundle. A mixed drop
  is never flattened into one control set.
- **Scrub sits in the footer as a guarantee** with its four levels, a one-line explanation each, and
  a "what was found" disclosure.
- **"Adjust for content" is deleted.** The behaviour is hard-wired on; a line of text says so rather
  than leaving a toggle nobody should turn off.

## The file row

Filename **first and highest layout priority** — it middle-truncates only when genuinely out of
room, and never before the numbers do. Order: `[kind badge] filename … [size pair] [savings pill]`.
The size pair is mono so it aligns; the savings pill is accent-tinted and appears only when there is
a real saving. While running, **the row is its own progress bar**, the accent fill sweeping behind
the text.

The three per-row actions moved to the toolbar (operating on the selection) and stay reachable in
the context menu.

## Toolbar and log

Toolbar, left → right: sidebar toggle · mark and title · then right-aligned, the quick actions on
the **selection** — Quick Look, Compare, Show in Finder — a divider, the log toggle, Settings.
**Nothing joins this bar without something else leaving it.**

The log is a **right sidebar, not a window**, symmetrical with the plan. **No frost:** flat surface,
dense monospace. A blurred backdrop behind 12px monospace is where frost stops being decoration and
starts costing legibility.

## Telling the truth

- A file trinket cannot improve is marked **amber and named** — never given a progress bar that
  never moves, and never quietly omitted.
- The pre-run number is labelled **"Est."** because it is a heuristic; every row's figure is
  replaced with a measured one as the file lands.
- A file that got *bigger* shows no savings pill. A batch that saved nothing says "Nothing left to
  squeeze" rather than printing 0%.
- "Nothing but pixels" cannot fully strip a PDF — macOS re-injects a producer name and timestamps on
  every write — and the Settings copy says so.

## Don'ts

- Don't add a control to the main bar without removing one.
- Don't paint any control in the system accent, or leave a stock focus ring.
- Don't use the accent on labels or kind badges; don't lighten it.
- Don't build a fixed 1-2-3 wizard, or split an image re-encode into two stages.
- Don't claim a capability the engine does not have.
