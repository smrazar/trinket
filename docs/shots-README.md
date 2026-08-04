# Screenshots for the Pages site

`Tools/site.json` names the feature rows in order. Replace a file in place and
`python3 Tools/make-site.py` picks it up — nothing else to edit.

| File | Row | What it shows |
|---|---|---|
| `img/trinket-demo.mp4` | 01 | The hero clip. A `.mp4` in a feature's `shot` renders a `<video>` rather than an `<img>`; `img/trinket-demo.jpg` beside it is picked up automatically as the poster. |
| `welcome.jpg` | 02 | First launch: the three promises, and the fact that the common case needs no configuration. |
| `plan.jpg` | 03 | A drop of photos, a document, a video and an archive, with the plan sidebar showing a lane per kind and a real "Est. … smaller" figure. The screen that explains the whole app. |
| `compare.jpg` | 04 | Before and after side by side — 7.7 MB against 132.1 KB, and no visible difference. Answers the first objection to "it will be smaller". |
| `scrub.jpg` | 05 | The metadata inspector: GPS with the map, the camera serial, and "Thumbnail of uncropped original", all tagged REMOVE. The most persuasive thing the app can show. |
| `archive.png` | 06 | A finished archive run — Unpack ticked, the photos and the video inside converted, Bundle naming the zip that came back out. |
| `done.jpg` | 07 | The payoff banner with per-file percentages, including the honest small ones (1%, 2%) that prove the number is measured rather than advertised. |

`about.png` is not a site row — it sits under the app icon at the top of `README.md`.

`docs/img/trinket-demo.gif` is the README's copy of the clip: 3× speed, 640px, 10fps, 1.9 MB.
**GitHub will not embed a player for a video committed to the repository** — a `<video>` element is
stripped by the sanitizer, and a bare URL or image syntax renders a plain link. All three forms were
tested against GitHub's markdown API. Inline playback is reserved for assets on GitHub's attachment
CDN, so the README gets a GIF and the site gets the mp4.

---

## The rule: never shoot your own files

**1.0 shipped two screenshots showing a real client's job number and project name**, and they were
live on the public site for a day. See the incident write-up in `docs/BUGS.md`. A screenshot is a
data export, and no scanner can read the text rendered inside a PNG — `scan-personal-data.py` reads
bytes and will call an image clean while a filename sits in it in 24pt type.

So: **every file in a shot is generated for the shot.** Nothing personal, nothing from a client,
nobody's face, no real coordinates. Rebuild the fixtures with the steps below, and read every
filename visible in the frame before committing an image.

**Two shots break that rule on purpose, at the owner's explicit call**, and it is worth saying which
so nobody "fixes" them later or assumes the rule was forgotten:

- `about.png` shows **Version 1.0** while the current release is 1.1. Retaking it is a minute's
  work; it was published as-is deliberately.
- `compare.jpg` uses a real photograph with a **date stamp burned into the pixels** and a filename
  naming the place it was taken. Both were pointed out and approved before it went up.

Everything else on the site is synthetic. When a shot needs a real photograph, the safe version is
below: keep the picture, replace the metadata.

**Screenshots of the app itself still need cleaning.** A macOS screen capture carries
`UserComment = Screenshot`, a DPI block and a Display P3 profile. Crop to the window, flatten to
sRGB *before* dropping the profile — the numbers survive a profile strip and their meaning does
not — and rewrite with a fresh properties dictionary:

```swift
// crop → draw into an sRGB CGContext → CGImageDestinationAddImage(dest, flat, [:])
// The empty dictionary is the point: nothing unenumerated rides along. Same rule as the app.
```

### The fixtures

The photographs are architectural frames with no people in them. Everything else is synthesised.

**`brochure.pdf`** — a multi-page document that is nothing but those frames:

```swift
// CGContext(url, mediaBox:) → beginPDFPage / draw(image) / endPDFPage per page.
// A real PDF with a real page count, and no author, client or title block.
```

**`IMG_2043.jpg`** — the photo the scrub shot inspects. Take any frame with no people, then copy
the *encoded image data* through and replace only the metadata, so the embedded IFD1 thumbnail
survives and the real coordinates do not:

```swift
CGImageDestinationAddImageFromSource(dest, source, 0, props)
// props: GPS 51.5007 N / 0.1246 W (a public landmark), Make/Model "Canon EOS R6",
//        BodySerialNumber "042031000537", Software "Adobe Lightroom 14.2" — all invented.
```

`CGImageDestinationAddImageFromSource` is the important part: it keeps the original compressed
bytes, so the "thumbnail of the uncropped original" that the shot is about is genuinely still in
there rather than being claimed.

**`photos.zip` / `trip-photos.zip`** — `zip -0` over the same frames. Stored, not deflated, because
that is the honest starting point for the "zipping JPEGs does nothing" story the archive shot tells.

### Taking them

Open the app on the fixtures — `open -a trinket <files>` works as of 1.1 — then capture the window
alone, with no desktop behind it:

```bash
WID=$(swift - <<'EOF'
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerName as String] as? String ?? "").lowercased().contains("trinket") {
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    if let h = b["Height"] as? Double, h > 400 { print(w[kCGWindowNumber as String] as? Int ?? 0); break }
}
EOF
)
screencapture -x -o -l "$WID" docs/shots/plan.png
```

The sheet-based shot (`scrub`) captures correctly this way too — a SwiftUI sheet is drawn into the
host window, so it lands in the same image.

`screencapture` needs **Screen Recording permission** for whatever runs it. Without it every capture
is solid black, which reads as a rendering failure and is not one.

Aim for a window around 1200 × 800, which captures at 2400 × 1600 on a Retina display — the size the
other apps' sites use. Then downscale and convert, because a photo-heavy PNG screenshot runs to
several megabytes:

```bash
sips -Z 2400 docs/shots/plan.png
sips -s format jpeg -s formatOptions 86 docs/shots/plan.png --out docs/shots/plan.jpg
```

Keep PNG where the frame is mostly UI chrome and text; use JPEG where it is mostly photographs. The
whole set should come in under about 3 MB.

### The video

Screen-record the app, then join and compress the parts **locally** — never through an online
converter. A free web converter burns its own watermark into every frame, which on the site of an
app whose entire pitch is "nothing leaves your Mac" is the worst possible advertisement, and it
means the recording was uploaded to a third party before it got there.

```bash
FF=/Applications/trinket.app/Contents/Resources/bin/ffmpeg
printf "file '%s'\n" part1.mp4 part2.mp4 > concat.txt
$FF -f concat -safe 0 -i concat.txt -c copy combined.mp4
$FF -i combined.mp4 -c:v libx264 -crf 30 -preset slow -pix_fmt yuv420p \
    -movflags +faststart -map_metadata -1 -an docs/img/trinket-demo.mp4
```

`-c copy` on the join means no re-encode and no generation loss. `-map_metadata -1` drops the
recording's own metadata, `-an` drops the audio track the page does not use. A minute of UI at
1094 × 720 lands under 1 MB — smaller than the watermarked version it replaced, at a higher
resolution.

**Watch the whole thing before committing it**, or at least a contact sheet of it:

```bash
$FF -i docs/img/trinket-demo.mp4 -vf "fps=1/5,scale=520:-1,tile=4x3" -frames:v 1 contact.png
```

A recording shows every filename in the window for its whole duration, which is a far larger
surface than a single screenshot.
