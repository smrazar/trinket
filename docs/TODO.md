# TODO

Ordered by value. Each item says what "done" means, so it cannot be half-finished and forgotten.

---

## 1. Look at the screens nobody has looked at

Written, compiling, logic-checked, **appearance unverified**: the batch-wide scrub report sheet,
the analysing state, and the Documents and Log settings tabs.

Cleared in 1.1 by actually opening them: the compare sheet, the metadata inspector with its map,
the renaming sheet, Settings › General, the plan sidebar with a five-lane mixed drop, the finished
banner in both list and thumbnail views, and the archive round trip end to end.

**Done means:** a screenshot of each, and any visual bug found written into `docs/BUGS.md`.

## 2. Decide what the map costs

`MKMapSnapshotter` fetches tiles from Apple, so the "where this was taken" panel sends the photo's
coordinates off the machine — in the one view built to show you a coordinate you are about to
remove. The file never leaves, so the headline claim holds, but this deserves a decision rather
than a silence.

**Done means:** either the panel is opt-in behind a click, or the About copy carries a footnote
saying the map is the one thing that touches the network. Not both, and not neither.

## 3. Mid-file progress for images and PDFs

Video moves — ffmpeg's `-progress pipe:1` is parsed, and the batch bar is weighted by bytes. An
image or document row still goes queued → running(0) → done. Fast enough that it rarely shows; a
200-page PDF is where it will.

**Done means:** a 200-page PDF shows a moving bar.

## 4. The floating drop target

The floating **result card** is built and honours its preference. The floating **drop target** —
the other half of the design bundle's floating mode — is not. Decide whether it earns its place
before building it.

**Done means:** either it exists, or a line in `docs/DESIGN.md` says why it does not.

## 5. Smaller things

- [ ] `Estimate` ratios are heuristics — good to roughly ±15% on the sample set. If they ever need
      to be exact, encode one file and scale the batch by its measured ratio.
- [ ] The N-archive case (several zips in one drop) is symmetric with the single-archive case and
      has no dedicated check.
- [ ] That `application(_:open:)` exists at all is not pinned by an assertion — deleting the method
      would fail nothing. The inbox behind it is checked.
- [ ] The `shelf` version for trinket is `v1.1` in this repo's `Tools/site.json`. The same array
      lives in every sibling app's `site.json` and they all still say `v1.0`.

---

## Publishing

The procedure, the personal-data scan and the pre-push checklist live outside this repo, in
`do not upload/trinket/PUBLISHING-CHECKLIST.md`. They reference machine layout and account
details that have no business in a public tree.

**Read every filename visible in a screenshot before committing it.** 1.0 published a client's job
number this way and it was live for a day; `docs/BUGS.md` has the incident and
`docs/shots-README.md` has the fixture recipe that replaces it.

**Publishing is one-way. Ask before pushing.**
