# The road to v2

v1.0 does the job it set out to do: drop files, get a plan, press one button, get smaller files
with nothing hiding inside them. Everything below is about the *distance between the app and the
moment you need it* — because right now that distance is "find the app, open it, drag files in",
and almost every idea here shortens it.

Ordered by value per unit of work. Each says what it is, why it matters, and what makes it hard.

---

## 1. Meet the files where they already are

**The single highest-value thing left.** Today trinket only works if you go to it. Almost nobody
thinks "I'll open a compression app" — they think "this photo is too big to email" while looking at
the photo in Finder.

- **Finder Quick Action** — right-click a selection → *Shrink with trinket*. An `NSExtension` of
  type `com.apple.services`, shipped inside the app bundle. It should run the standing defaults
  silently and show the floating result card, with no window at all. That is the whole feature:
  select, right-click, done.
- **Share sheet extension** — trinket appears wherever macOS offers Share, so a photo can be made
  sendable from inside Photos or Mail.
- **Services menu entry** for the same action, free once the extension exists.

**Hard part:** an app extension is a separate bundle with its own sandbox and its own signature,
and it cannot reach the main app's `UserDefaults` without an App Group. The engines are already
pure enough to link into a second target — `Model/` touches no AppKit and no filesystem — so the
work is bundle plumbing, not rewriting.

**Why first:** it turns trinket from a place you go into a thing that is already there. Nothing
else on this list changes usage as much.

## 2. Presets

The plan is excellent at answering "what should happen to *these* files". It has no memory of
"what I always do for *this purpose*".

- Named presets: **For email** (≤ 5 MB, share-safe), **For the web** (1600px, JPEG, nothing but
  pixels), **Archive it** (lossless, keep everything), **Send to a client** (PDF, scrubbed).
- Pick one from the sidebar header; it fills every lane at once.
- A preset is just a `PlanDefaults` plus a name, so the model already supports it — `Defaults.adopt`
  is nine tenths of the way there.

**Why:** it is the difference between an app that can do anything and an app that does *your* thing
in one click. It also makes the Quick Action above meaningful — a right-click menu with four named
presets is far more useful than one that runs whatever the app was last set to.

## 3. Watch a folder

Point trinket at a folder; anything that lands in it gets the plan applied and moves on. The
screenshots folder, the phone-import folder, the scanner's output folder.

**Hard part, and it is a real one:** the write-settle problem. A file appearing in a folder is not
a file that has finished being written — a 200 MB video copied over Wi-Fi appears immediately and
grows for a minute. Watching needs `FSEvents` plus a settle window (size stable across two polls,
and no open file handle) before touching anything. Get this wrong and you convert half a file.

Also needs a loop guard: the output must never land somewhere the watcher is watching, or trinket
converts its own output forever.

## 4. Sign it properly

The zip is ad-hoc signed, so Gatekeeper blocks it and the honest advice is "build from source".
That is a real barrier for anyone who is not already a developer — which is most people.

A paid Developer ID (~$99/year) plus notarisation turns the download into a normal double-click.
**This is the only item on the list that costs money rather than time**, and it is the one that
decides whether trinket has users or just a repository.

## 5. Finish what v1 started

- **Per-file progress for images and PDFs.** Only video reports movement; a 200-page PDF rebuild is
  silent. The mechanism exists, it just needs feeding from those two passes.
- **The floating drop target** — the other half of the design bundle's floating mode. A small
  always-there target to drag onto. Decide whether it earns its place before building it; the
  Quick Action above may make it redundant, which would be the better outcome.
- **A batch that survives a quit.** Right now quitting mid-run loses the queue.

## 6. Formats worth adding

- **AVIF and JPEG XL** — meaningfully smaller than JPEG at the same quality. macOS 15 can read AVIF;
  writing may need the bundled ffmpeg, which is already there.
- **Animated GIF → MP4.** A 12 MB GIF becomes a 400 KB video. Common, and a big visible win.
- **`docx`/`pptx`** stay out of scope: rewriting OOXML means owning it, and that is a different app.

## 7. Scrub, further

The scrub is the differentiator, so it is worth pushing.

- **A verification report** — export a before/after list of exactly what was removed from each
  file. For anyone who has to *prove* a document was cleaned, that is the whole product.
- **Video metadata is all-or-nothing** today (`-map_metadata -1`). Per-field video scrubbing would
  match what images already do.
- **PDF's ceiling is documented but not solved.** macOS re-injects Producer and timestamps on every
  write. Solving it means writing PDF bytes directly rather than via PDFKit — a large job, and only
  worth it if someone actually cares about that last field.

---

## Deliberately not doing

- **Cloud anything.** "No file ever leaves your Mac" is the promise; the moment there is an upload
  path it is a different app with a different threat model.
- **A file manager.** trinket converts files. It does not organise them.
- **Windows or Linux.** The engines are ImageIO, PDFKit, AVFoundation and `afconvert` — the app
  *is* its platform bindings.
- **RAR.** unrar's licence does not permit redistribution.

## What v2 actually means

**v2 is when trinket stops being an app you open.** Items 1 and 2 together — the Quick Action and
presets — are the version bump. Everything else is refinement of v1.
