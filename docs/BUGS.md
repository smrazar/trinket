# Bug catalog

Every bug found in the rewrite, with its **root cause** and the **check that now pins it**. The
point of this file is that no future session re-finds, re-diagnoses, or re-introduces one of these.

A bug counts as closed only when a runnable assertion would fail if it came back. Where there is no
check, the row says so — an unpinned fix is a fix waiting to regress.

---

## Closed — pinned by a check

### 1. The embedded-thumbnail detector reported true for every file
**Symptom:** the scrub's flagship claim — "we remove the thumbnail of the uncropped original" —
appeared to apply to files with no embedded thumbnail at all, including files trinket had just
written itself.
**Root cause:** `CGImageSourceCreateThumbnailAtIndex` *renders* a thumbnail from the full image and
returns it, even with `kCGImageSourceCreateThumbnailFromImageAlways: false` **and**
`…FromImageIfAbsent: false`. ImageIO offers no way to ask "is one actually stored?".
**Fix:** parse the bytes — walk the JPEG segments to APP1/`Exif`, read the TIFF header, follow
IFD0's next-IFD pointer to IFD1, look for tag `0x0201` (`JPEGInterchangeFormat`).
**Check:** `MetadataPass.thumbnailDetectorCheck()` writes one JPEG with
`kCGImageDestinationEmbedThumbnail` and one without, asserting false then true. Reverting to the
ImageIO call fails the first assertion.
**Also verified against real files:** camera JPEGs → true, synthesised JPEGs → false.

### 2. A PDF's scrub was silently cancelled when the rewrite grew the file
**Symptom:** share-safe left the `Creator` attribute in place on some PDFs.
**Root cause:** when the page rebuild came out larger than the source (a vector/text PDF with
nothing to squeeze), the fallback copied the **original file** back — restoring every attribute the
user had asked to remove. A size optimisation quietly cancelled a stated guarantee.
**Fix:** fall back to the original *pages* with scrubbed attributes, never to the original bytes.
Copying the file is reserved for `keepEverything`, where there is nothing to lose.
**Check:** `DocumentPass.selfCheck()` — the probe PDF is vector art, so it takes the fallback path,
and the check asserts `creatorAttribute == nil` on the result.

### 3. Pass-through files were dropped out of the repacked archive
**Symptom:** a zip came back with fewer entries than it went in with.
**Root cause:** two different pass-through paths. `process()` copied the file through; the
lane-level "this kind has no stage" branch only set the row amber and never copied. So anything
handled by that branch existed as a row and not as a file, and the repack could not find it.
**Fix:** every pass-through routes through `copyThrough`. One path, one behaviour.
**Check:** `PipelineCheck.archiveRoundTrip` asserts the repacked archive still holds all three
entries, including the `.bin` nothing can be done to.

### 4. An archive dropped alongside other files was never opened
**Symptom:** a 145 MB zip dropped together with some photos came back byte-for-byte unchanged while
the photos shrank.
**Root cause:** the analyser only unpacked an archive when it was the *single* dropped item —
"several archives at once stay closed" over-applied to the one case the app exists for.
**Fix:** every dropped archive is opened. Each entry records its container, so a mixed drop still
knows which file came from where, and loose files stay loose.
**Check:** `PipelineCheck.archiveDroppedAlongsideLooseFiles` drops `[loose.jpg, album.zip]` — two
items, archive deliberately *not* first, so a rule keyed on "only item" or "first item" fails it.

### 5. Video inside an archive passed through at full size
**Symptom:** photos in a zip shrank; the video in the same zip came out unchanged, even with the
plan showing a `Convert · H.264` stage and ffmpeg present.
**Root cause:** `Runner.process` gated on `ArchivePass.canShrinkInsideArchive(kind)`, which allowed
images only. That rule was inherited from an older engine that re-encoded images *in place* inside
the container. This rewrite unpacks every entry to disk first, so the container is irrelevant — the
restriction described a constraint that no longer existed.
**Fix:** the gate is deleted. An entry goes through the same pass a loose file does.
**Check:** `PipelineCheck.videoInsideAnArchiveShrinks` synthesises a deliberately wasteful clip with
ffmpeg, zips it, runs the plan, and asserts the video ends `.done` and smaller. Skipped — not
failed — when the build has no ffmpeg.

### 6. Unchanged images were renamed `.jpg` → `.jpeg`
**Root cause:** `UTType.preferredFilenameExtension` answers `"jpeg"`, and the output filename used
it unconditionally, so a folder of `.jpg` photos came back renamed for no reason the user asked for.
**Fix:** keep the source's own extension when the format did not change; use the canonical one only
for a real conversion.
**Check:** `ImagePass.selfCheck()` asserts `.jpg` in → `.jpg` out, and that converting to PNG does
take `.png`.

### 7. Status colours were unreadable as text
**Root cause:** the design contract's amber `#f59e0b` measures **2.2:1** on white and its green
`#34c759` about **2.5:1**. Both are fine as swatches; this app only ever uses them as *words*
("Not yet · passes through", "Complete").
**Fix:** darkened to `#A35F00` (5.0:1) and `#178036` (5.0:1), hue preserved.
**Check:** `Tokens.selfCheck()` asserts every status colour clears 4.5:1 on its surface, in both
light and dark.

### 8. `--self-check` deadlocked
**Root cause:** the CLI path blocked the main thread on a semaphore while waiting for `@MainActor`
work, which can only run on the thread it had just parked.
**Fix:** hand the whole run to the main actor and pump the run loop; `exit(0)` inside the task ends
the process.
**Check:** implicit but real — `package-app.sh` runs `--self-check`, so this hangs the build.

### 9. The "· default" badge pointed at a level the app did not use
**Root cause:** `ScrubLevel.recommended` was hardcoded to `.shareSafe` while the shipped default
became `.nothingButPixels`. The picker told the user something untrue about their own app.
**Fix:** `recommended` is asserted equal to `Defaults.Factory.scrubLevel`.
**Check:** `ScrubReport.selfCheck()`.

### 10. Primary buttons collapsed under `.fixedSize()`
**Symptom:** "Get started" rendered with its label touching both edges of the button.
**Root cause:** `PrimaryButton` had vertical padding and `.frame(maxWidth: .infinity)` but no
horizontal padding, so a `.fixedSize()` caller shrank it to exactly the text width.
**Fix:** horizontal padding always; `fillsWidth: false` for self-sizing callers.
**Check:** none — visual only. See the last section.

### 11. Settings controls formed a ragged column and the path truncated mid-word
**Symptom:** `~/Downloads/trinket` rendered as `…wnloads/trinket`, losing the one word that
identifies the folder; each row sized to its own control so the right edge zigzagged.
**Root cause:** head-truncation on a path, and no shared control column.
**Fix:** a fixed 200pt control column (`SettingsRow.controlColumn`); the path moved onto its own
full-width line with middle truncation.
**Check:** none — visual only.

### 12. Scrubbing waived the "never hand back a bigger file" rule
**Symptom:** a 166.2 KB photo came back as 222.2 KB. Same format, same 721 × 540 pixels — the only
difference was one metadata item removed. Seen in the compare sheet on a real batch.
**Root cause:** the size guard was a **veto after the encode**, not a ceiling on it, and it had two
exemptions: a format change, and "the scrub removed something". The second is far too broad. Once
any metadata was being stripped — which is the *default* — the file was allowed to grow without
limit, and the target size did nothing because the file already fit under it. The reasoning written
in the comment ("the larger file is the point") is true for a format change and false here: nobody
asks for a 34% larger file to drop one EXIF tag.
**Fix:** `ImagePass.encodeCeiling` — the target size and the original size are both ceilings and the
smaller wins, so the quality search walks down until the result actually fits. Only a format change
lifts the original-size ceiling. Copying the original bytes back is still refused whenever the scrub
found something, because a smaller file that still carries your coordinates is the worse outcome.
**Check:** `ImagePass.selfCheck()` asserts a low-quality 512 × 384 JPEG re-encoded at quality 0.9
under a 250 KB target with `.nothingButPixels` does not grow, *and* that its GPS is gone — so the
ceiling cannot be bought by skipping the scrub. Four unit assertions pin `encodeCeiling` itself.
**Why the old check missed it:** there was already a never-bigger assertion, and it passed. It ran
with `.keepEverything`, which takes the copy-the-original path before the encode is ever consulted,
and its fixture was a 64 px probe too small for a re-encode to grow measurably. **A fixture shaped
like the happy path proves nothing.** Reverting the fix now fails with `76905 → 192870`.
**Measured after the fix,** on the same file that produced the symptom: 166,245 → 158,865 bytes.
Across a 22-file batch, zero outputs grew.

### 13. "Open With trinket" launched the app and threw the files away
**Symptom:** trinket appeared in Finder's *Open With* menu — `Info.plist` has declared
`CFBundleDocumentTypes` for images and documents since 1.0 — and choosing it opened an empty
window. `open -a trinket file.jpg` did the same. Drag-and-drop was the only way in.
**Root cause:** nothing implemented `application(_:open:)`. Declaring a document type is a promise
made to LaunchServices; the delegate half was never written, so the URLs were delivered and
discarded.
**Fix:** `AppDelegate.application(_:open:)` hands the URLs to `FileInbox`, which the window drains.
A buffer rather than a notification, because a cold launch delivers them before any window exists.
**Check:** partially — bug 14's check exercises the inbox. That the *delegate method exists* is not
mechanically pinned; deleting it would fail no assertion.

### 14. A multi-file "Open With" lost all but the last delivery
**Symptom:** opening 14 files analysed 13. The video was simply absent — no error, no amber row,
nothing in the log to say a file had been dropped.
**Root cause:** macOS does not hand a multi-file open to `application(_:open:)` in one call. It
arrived as one call with thirteen URLs and a second with one. Each call published straight to the
window, and loading a batch **resets** the previous one, so the last delivery won and everything
before it was silently discarded. Found on the first real test of bug 13's fix — the code was
written and looked obviously correct.
**Fix:** `FileInbox.deliver` accumulates and publishes only once a 400 ms settle window has passed
with no further delivery, so a burst becomes one batch.
**Check:** `PipelineCheck.splitOpenDeliveryArrivesWhole` delivers 13 then 1, asserts nothing is
published mid-burst, then asserts all 14 arrive with the `.mp4` last. Reverting to the naive
version fails with "the inbox published a half-delivered batch".

### 15. Every result tile was a grey placeholder after an archive run
**Symptom:** finish a batch that came from a zip, switch to thumbnails, and all twenty tiles show
the generic picture icon. The one view whose entire job is answering "which file is this?" answered
it for none of them.
**Root cause:** a tile renders `item.outputURL ?? item.url`. After an archive run the individual
results are bundled into the output zip and their intermediates deleted — an archive in, an archive
out — so every `outputURL` pointed at a file that no longer existed, and `QLThumbnailGenerator`
returned nothing for all of them.
**Fix:** `FileThumbnail` takes a `fallback` and uses the original when the output cannot be
rendered. The original is still on disk and shows the same picture. Both call sites pass it — the
168pt grid tile and the 38pt detail row had the same bug.
**Check:** none — visual only, and the failure mode is a missing image rather than a wrong value.

---

## Open / not yet pinned

- **Small-window sweep is incomplete.** The payoff headline and the sidebar estimate now wrap
  instead of overflowing, and sheets size ideally rather than fixedly — but Settings, the sheets and
  the breadcrumb strip have not each been eyeballed at the 720pt minimum. *(task: small-window
  layout)*
- **Multiple archives in one drop** each get their own staging folder and their own output zip. The
  logic is symmetric with the single-archive case, which is covered; the N-archive case has no
  dedicated check.
- **Images and PDFs still report nothing mid-file.** Video now moves — ffmpeg's `-progress pipe:1`
  is parsed and `Runner.progress` is weighted by bytes — but an image or document row still goes
  queued → running(0) → done. They are fast enough that it rarely shows; a 200-page PDF is the
  case where it will.
- **Result thumbnails were seen blurred once, and it has not been reproduced.** After a batch of 8
  photos the tiles rendered as heavy blurs rather than pictures (screenshot, 1.0, 2026-08-04
  01:40). Re-running the identical 8 files on 1.1 produced sharp tiles, twice. Ruled out by
  measurement, not by argument: `QLThumbnailGenerator` returns a sharp 672 × 504 type-2
  representation for a freshly written scrubbed JPEG, including 8 requested concurrently while the
  files are still being written; `NSImage(cgImage:size:)` handles the zero `contentRect` correctly;
  `ThumbnailCache` is a plain dictionary. The remaining suspicion is that a degraded representation
  was returned under some load and then cached for the session, since nothing ever re-requests —
  but that is a hypothesis with no measurement behind it and it is written here as one.

---

## Platform behaviour that only looks like a bug

- **PDFKit re-injects `Producer`, `CreationDate` and `ModDate` on every write.** Nothing can
  suppress them, so "Nothing but pixels" cannot fully deliver on a PDF. The Settings copy says so.
  `DocumentPass.selfCheck()` asserts the re-injection *still happens*, so if a future OS stops doing
  it the check fails and the copy gets corrected rather than silently going stale in the other
  direction.
- **An already-compressed archive gets bigger, not smaller.** JPEG/MP4/PDF have no redundancy left,
  so a high zip level adds container overhead — measured at 145.3 MB → 146.7 MB, slowly. The planner
  drops to level 1 for incompressible contents (same bytes, far faster) and the sidebar explains it.
  The real answer is the different verb the app is built around: shrink what is *inside*.

---

- **The metadata map needs the network, and the app claims to work offline.** `MKMapSnapshotter`
  fetches map tiles from Apple, so opening "where this was taken" sends that photo's coordinates
  off the machine. Measured: the map panel stays empty for roughly ten seconds and then fills. The
  file itself never leaves — "no file ever leaves your Mac" is still true — but *the coordinates
  do*, in the one panel built to show you a coordinate you were about to remove. Nothing else in
  the app touches the network. Either the claim needs a footnote or the map needs to be opt-in.

---

## Shipped data incidents

**A screenshot put a client's project name on the public site.** `docs/shots/plan.png` and
`scrub.png` shipped in 1.0 and were live at `smrazar.github.io/trinket` from 2026-08-03, both
showing a file list containing a real job number, place and project type. The same document's cover
renders inside the app's compare sheet, naming a consultancy and a government department.

**And `docs/STATUS.md` published a real GPS coordinate in prose** — the evidence column for the
scrub row gave a latitude and longitude to three decimal places as proof that the scrub had removed
them. A precise location the owner had actually been, committed to a public repository as evidence
that the app removes precise locations. Found in the same sweep and replaced with the claim minus
the datum. (The coordinate is deliberately not repeated here; quoting it in the bug report would
republish exactly what the bug report is about.)

This is the second and third time — see `publishing-to-github.md` §11, fix commit `bced4cc` in
`smrazar/loupe` — which makes it a process failure rather than an accident:

- **A screenshot is a data export.** It was reviewed for *layout*, and never read for *content*.
  The filenames were right there in 24pt type.
- **`scrub.png` was not even the screen it claimed to be.** It was a near-duplicate of `plan.png`,
  not the metadata inspector — so nobody had opened either file after committing them.
- **The rule that works:** shoot from files you generated for the purpose. Every image in 1.1 is
  built from a synthetic fixture — a brochure rendered from architecture frames, a zip packed for
  the shot, and one photo whose GPS was rewritten to a public landmark and whose serial was
  invented. `docs/shots-README.md` records how to rebuild them.
- **Read every filename in the frame before committing an image.** No scanner does this; the
  personal-data scanner reads bytes and cannot see rendered text.
- **A measurement is evidence; the value you measured may be private.** "GPS present in source,
  absent from result" proves exactly as much as printing the coordinate did. Prefer the claim to
  the datum whenever the datum is the user's.
- **Grep for the shape, not the string.** A coordinate has no keyword to search for, which is why
  it survived every scan. `[0-9]{2}\.[0-9]{3}, *-?[0-9]{2,3}\.[0-9]{3}` finds it; "GPS" does not.

---

## Cannot be checked mechanically

**Only a human looking at the app finds a visual or interaction bug.** Bugs 10 and 11 above were
both invisible to a passing test suite and obvious in a screenshot.

`screencapture` **does** work from an agent session, but the invoking process needs Screen Recording
permission; without it every capture is solid black, which is easy to misread as a rendering
failure rather than a permission one. Per-window capture (`screencapture -l <windowid>`) can also
fail with "could not create image from window" while a full-screen capture succeeds. Look at a UI
change before claiming it works.
