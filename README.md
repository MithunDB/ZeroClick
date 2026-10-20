<p align="center">
  <img src="Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png" alt="ZeroClick icon" width="112">
</p>

<h1 align="center">ZeroClick</h1>

<p align="center"><strong>Drop a file. Choose an action. Keep moving.</strong></p>

<p align="center">A local, menu-bar file utility for Apple silicon Macs.</p>

<p align="center">
  <a href="https://github.com/MithunDB/ZeroClick/releases">⬇️ Download ZeroClick.app</a>
  &nbsp;·&nbsp; <a href="#quick-start">Quick start</a>
  &nbsp;·&nbsp; <a href="#whats-inside">What's inside</a>
</p>

> **Early access:** The downloadable build is usable but still in development. Protected ZIPs, ZeroClick-created encrypted files, and PNG message hiding are planned, not included yet. The AI wheel is a disabled preview.

ZeroClick works from a Finder drag. It reads and writes files locally, with no uploads or telemetry. Conversions and editing tools save new copies; only the explicit **Move** action relocates a selected file.

ZeroClick is a private local derivative of Satsuma, an open-source reimplementation of the Tangerine workflow: 190 conversion options across images, video, audio, documents, subtitles and archives, and 26 advanced file tools.

Password-protected PDFs can be unlocked into a separate unprotected copy. The original stays encrypted.

## Quick start

1. Open [Releases](https://github.com/MithunDB/ZeroClick/releases) and download the **ZeroClick-macOS-arm64.zip** asset. The automatic GitHub “Source code” archives contain source, not the app.
2. Unzip it, then move **ZeroClick.app** to Applications.
3. Open the app. It lives in the menu bar, so it will not add a Dock icon.
4. Start dragging a file in Finder and hold a modifier to show a wheel:

| Hold while dragging | Wheel | What it does |
| --- | --- | --- |
| **Shift** | Convert | Convert to compatible formats |
| **Shift + Option** | Tools | Open editors, compression, PDF tools, and more |
| **Command** | File actions | Copy Path, Duplicate, Move, ZIP, and more |
| **Option** | AI · Coming later | Shows planned actions; nothing runs |

ZeroClick requires an **Apple silicon Mac with macOS 26 or later**. The downloadable app does **not** require Brisk, Xcode, or a Git clone. Some non-native formats need optional `ffmpeg`; RAR extraction needs optional `unar`. This early-access build is ad-hoc signed, not Developer ID notarized, so macOS may ask you to approve opening it in **System Settings → Privacy & Security** on first launch.

## What's inside

- **190 conversion routes** across images, audio, video, documents, subtitles, and archives.
- **26 local tools** for editing, redaction, compression, PDF pages, and more.
- **Safe outputs** with collision-resistant names, staged writes, cancellation, and operation history capped at 50 entries.
- **Private by design:** no account, cloud processing, telemetry, or AI backend.

## How it works

1. Start dragging one or more files in Finder (or any app).
2. Hold **Shift**. A radial menu appears around the cursor with the formats the selection can be converted to.
3. Move over a format and release to convert. Copies are written next to the originals (or to the folder chosen in Settings).
4. Hold **Shift + Option** instead to switch the radial menu to advanced tools (Compress, Crop, Trim, Merge PDFs, …). Settings can map this wheel to **Command** instead. Releasing on a tool opens its window with a live preview.
5. Hold **Command** for local file actions. Control also maps to file actions, but a pre-held Control-click can open Finder’s context menu before dragging. Hold **Option** alone to see future AI actions marked “Coming later”; those actions cannot be selected.

Keyboard: while the radial menu is open, press **Option** to toggle between formats and tools, arrow keys to choose, **Return** to apply, **Escape** to cancel.

ZeroClick lives in the menu bar (no Dock icon). The status item shows job progress and opens Settings.

## Look and feel

The radial menu is built from Liquid Glass wedges (`glassEffect` on a custom rounded annular-sector `Shape`, grouped in a `GlassEffectContainer`), with the selected wedge tinted orange and a glass centre pill naming the selection. Tool windows use the stock macOS title bar (title + file subtitle), card-grouped content, standard AppKit/SwiftUI controls with an orange accent, overlay scrollbars where content is taller than the window, and a bottom Cancel/Save bar. Every icon is an SF Symbol. Light and dark appearance follow the system, or can be forced in Settings.

## Conversions

| Source | Targets |
| --- | --- |
| JPG, PNG | PNG/JPG, WebP, HEIC, TIFF, AVIF, BMP, PDF, DOCX |
| WebP, HEIC, TIFF, SVG, AVIF, BMP | JPG, PNG, WebP, HEIC, TIFF, AVIF, BMP, PDF |
| MP3, M4A, WAV, FLAC, OGG, Opus, AIFF, WMA | every other audio format |
| MP4, MOV, MKV, WebM, AVI, WMV | every other video format, GIF, MP3 |
| GIF | MP4, MOV, MKV, WebM, AVI, WMV |
| PDF | DOCX, JPG, PNG (all pages, 300 DPI), TXT |
| TXT | PDF, JPG, PNG, SRT, VTT |
| SRT, VTT | VTT/SRT, TXT |
| ZIP, TAR, GZIP, RAR | ZIP, TAR, GZIP (RAR can be read, not written) |

Native frameworks are used first: ImageIO/Core Graphics for images, AVFoundation for audio and video, PDFKit/Core Text for documents, Foundation for archives. `ffmpeg` is used only for formats Apple's frameworks cannot encode or decode (WebM/VP9, MKV, AVI, WMV, OGG, Opus, FLAC output, WMA, MP3 encoding, animated GIF export). `unar`/`bsdtar` extracts RAR.

## Advanced tools

| Scope | Tools |
| --- | --- |
| Any file | Compress (Balanced/Strong, target size, resize), Edit metadata (view, edit, strip sensitive or all fields) |
| Images | Edit photos, Add a background, Crop, Redact, Resize, Rotate, Create a PDF, Make a collage |
| Video | Trim, Split, Crop, Change speed, Join, Save frames, Redact |
| Audio | Trim, Normalize volume, Convert channels, Bleep, Create an audio visualizer |
| PDF | Merge, Organize pages, Split, Unlock protected PDF into a new copy |

Image redaction can suggest face or text areas locally with Vision. Review and adjust the boxes before confirming export. Blur and Pixelate have per-area strength sliders from 1× to 8×; use Solid for sensitive text because blur and pixelation can leave details recoverable. Redacted output is a new copy without inherited EXIF/TIFF metadata.

## Build from source

- Apple silicon Mac running macOS 26 or later.
- [Brisk](https://github.com/plyght/brisk) and the Xcode command-line tools (`swiftc`) to build from source.
- Optional: `ffmpeg` for the non-native formats listed above (`wax install ffmpeg`), `unar` for RAR extraction (`wax install unar`). ZeroClick looks in `PATH`, `/opt/homebrew/bin` and `/usr/local/bin`; a custom path can be set in Settings.

```bash
brisk build            # debug .app in .build/debug/ZeroClick.app
brisk run              # build and launch
brisk test             # compile and run Tests/ with the app sources
brisk archive --release
```

ZeroClick needs **no Accessibility or Input Monitoring permission**. During a Finder drag it polls `NSEvent.pressedMouseButtons`, `NSEvent.modifierFlags`, `NSEvent.mouseLocation` and the system drag pasteboard (`NSPasteboard(name: .drag)`). The wheel appears only after Finder publishes a real drag; it reads files from that pasteboard or `NSDraggingInfo`. Moving more than 300 points from where the drag started cancels the wheel for that drag. It never installs key-event monitors or event taps. Progress shows in a floating card or a small pill under the notch (Settings > Appearance). Completion notifications are optional in Settings.

## Logs

ZeroClick writes a local activity log to `~/Library/Logs/ZeroClick/zeroclick.log` (drag selection, job start/finish, conversion steps, errors) and, if the process dies from a signal, a backtrace to `~/Library/Logs/ZeroClick/crash.log`. "Show Logs" in the menu bar menu reveals them in Finder. Nothing leaves the machine.

## Quality gates

```bash
scripts/check.sh        # format check, lint, build (type-check), tests
scripts/check.sh --fix  # apply swift-format fixes first
```

`scripts/check.sh` uses `swift-format` (Apple, ships with Xcode 16 / `wax install swift-format`), `swiftlint` (`wax install swiftlint`) when present, `brisk build` as the type-check and `brisk test` for the test suite. Missing optional linters are reported and skipped; the build and tests are mandatory.

## Verification status

Local `brisk test` passes 63/63 checks, and `brisk archive --release` produces an ad-hoc signed standalone `.brisk/Archives/ZeroClick.app`. Finder drag tests have verified conversion, PDF Tools, file-actions, the disabled AI wheel, text redaction, PDF merge/split/organize/compression, ZIP extraction, and password-protected PDF unlocking. Protected ZIPs, ZeroClick-created encrypted files, and PNG message hiding remain in development.

## Project layout

```
.brisk.toml                Brisk manifest (bundle id local.zeroclick.app, LSUIElement)
Sources/App                App delegate, status item, settings
Sources/Formats            FileFormat enum, ConversionMatrix (190 options, output naming)
Sources/Engines            Conversion engines: image, audio, video, document, subtitle, archive, ffmpeg bridge
Sources/Operations         Tool backends: ImageOps, VideoOps, AudioOps, PDFOps, MetadataOps, Compressor
Sources/Radial             Global drag/modifier monitor and the radial menu overlay
Sources/Core               Job runner, progress HUD (card and notch pill), shell, media probing
Sources/Tools              Tool window shell, tool registry and the 26 tool views
Tests                      Direct Swift tests run by `brisk test`
```

## Privacy

No network access, no telemetry, no analytics. Files are read from disk, processed in memory or in a temporary folder under the user's temp directory, and written back as new files next to the originals.

## Upstream and license

ZeroClick is a private local derivative of [Satsuma](https://github.com/plyght/satsuma), created by plyght. The upstream MIT license and copyright notice remain in `LICENSE`. This is not an official Satsuma build.
