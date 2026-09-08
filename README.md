# Loopwall

A small menu-bar app that plays an MP4 or GIF as your macOS wallpaper, on the
laptop screen and every external display. It compresses what you give it, so a
25 MB clip or a fat "HD GIF" turns into a couple of megabytes of HEVC.

Requires macOS 15+. No dependencies, no helper processes, no ffmpeg.

## Using it

1. Click the menu-bar icon (▶ over a rectangle) → **Open Loopwall…**
   (Double-clicking the app in Finder does the same.)
2. Drop an MP4/MOV/GIF onto the window, or hit **Add Video or GIF…**
3. Pick a size in the import sheet. It shows the resulting resolution and an
   estimated file size before encoding. **1080p** is the sweet spot for most
   displays; drop to 720p if you want it tiny.
4. Click the thumbnail to apply it.

**Per-display wallpapers:** the strip at the top targets where a click lands.
"All displays" is the default; select a specific display first to give it its
own video. Right-click a library item for "Set on <display>" directly.

Assignments are keyed to each monitor's hardware UUID, so unplugging and
replugging a display restores its wallpaper.

## Options menu (bottom-right)

| Setting | Default | What it does |
|---|---|---|
| Fill / Fit / Stretch | Fill | How the video maps to a non-matching aspect ratio |
| Pause when covered by a window | On | Stops decoding the moment the desktop isn't visible |
| Pause on battery | Off | For maximum laptop endurance |
| Pause in Low Power Mode | On | Follows the system setting |
| Pause when locked or screen saver runs | On | |
| Hide desktop icons | Off | Flips Finder's `CreateDesktop` default and restarts Finder |
| Cap imports at 30 fps | On | Halves the cost of 60 fps sources |
| Open at login | Off | Registers via `SMAppService` |

## Power behaviour

The wallpaper window sits at `kCGDesktopWindowLevel` — above the system desktop
picture, below the desktop icons. macOS's WindowServer already tracks whether
that window is visibly covered, so Loopwall listens for
`NSWindow.didChangeOcclusionStateNotification` rather than polling.

Measured on this machine, two displays playing 1080p HEVC:

```
visible    2.6% – 5.2% CPU
covered    0.0% – 0.1% CPU     (maximised window over the desktop)
uncovered  resumes immediately
```

A display with no wallpaper assigned gets no window at all, so your normal
system wallpaper shows through untouched.

## Compression

Everything is re-encoded to HEVC in an `AVAssetWriter` pass; audio is dropped
(the wallpaper is muted anyway). The bitrate is derived from the *output*
resolution — `pixels × fps × bits-per-pixel`, where bits-per-pixel rises for
smaller frames because they need more bits per pixel to stay clean.

Measured results:

| Source | Output | Size |
|---|---|---|
| 2560×1440 30 fps, 12.4 MB | 1920×1080, 5.2 Mbps | 3.3 MB (26%) |
| 3840×2160 60 fps, 23.2 MB | 1920×1080 30 fps | 3.9 MB (17%) |
| 1280×800 GIF, 1.3 MB | 1280×800 HEVC | 137 KB (10%) |

GIFs are always converted: AVFoundation can't play a GIF, and GIF is a terrible
codec for this. Frame delays are read per-frame from the GIF metadata (with the
usual sub-11ms → 100ms browser clamp), so timing is preserved.

HDR sources are tone-mapped to SDR during compression. If you want to keep an
HDR grade, import at **Original (no re-encode)**.

## Where files live

- App: `/Applications/Loopwall.app`
- Library: `~/Library/Application Support/Loopwall/` (`library.json` + `Media/`)
- Preferences: `defaults read com.octoberwip.loopwall`

Imported videos are *copied* into the library, so moving or deleting the
original file afterwards is fine.

## Building

```sh
xcodegen generate          # regenerate Loopwall.xcodeproj from project.yml
./build.sh                 # release build + install to /Applications
```

The Xcode project is generated, so edit `project.yml` rather than the
`.xcodeproj`. Source lives in `Loopwall/Sources`:

| File | Role |
|---|---|
| `LoopwallApp.swift` | `@main`, menu-bar scene, AppKit window controller |
| `AppState.swift` | Coordinates library, preferences, engine, imports |
| `WallpaperEngine.swift` | One desktop window + player per assigned display |
| `WallpaperWindow.swift` | The borderless desktop-level window |
| `PowerPolicy.swift` | Battery / lock / sleep / Low Power inputs, `shouldPlay` |
| `Transcoder.swift` | Compression and GIF→HEVC |
| `LibraryStore.swift` | On-disk library and index |
| `MainView.swift`, `ImportSheet.swift`, `MenuBarContent.swift` | UI |

Local dev builds are ad-hoc signed (`CODE_SIGN_IDENTITY: "-"`) and not
sandboxed, so `./build.sh` needs no Apple Developer team and can read files
you pick from anywhere without bookmark plumbing.

## Distribution

Ad-hoc signing only works on the machine that built it — anyone else's Mac
gets a Gatekeeper "can't be opened" wall. Shipping to other people needs a
**Developer ID Application** certificate, hardened runtime, and notarization.

```sh
./dist.sh          # archive → sign (Developer ID) → notarize → staple → build/Loopwall.dmg
```

One-time setup, since the App Store Connect API can't create this certificate
type: Xcode → Settings → Accounts → select the team → Manage Certificates →
**+** → Developer ID Application. `dist.sh` checks for it and tells you if
it's missing. Notarization runs through the `asc` CLI, which needs an
authenticated App Store Connect API key profile (`asc auth status`).

The resulting DMG is signed, notarized, and stapled — it opens with no
Gatekeeper warning on any Mac, offline included. Verify with:

```sh
spctl -a -vvv -t install build/Loopwall.dmg
```

`dist.sh` is entirely separate from `build.sh` and never touches `project.yml`'s
local signing config, so day-to-day development stays ad-hoc and fast.

## Releases & auto-updates

Loopwall checks for updates via [Sparkle](https://sparkle-project.org),
reading `appcast.xml` (raw-served from `main` on GitHub) and downloading new
versions from GitHub Releases. Users can also trigger a check manually from
the menu bar (**Check for Updates…**).

To cut a new release:

```sh
./release.sh 1.1 2   # <marketing-version> <build-number>
```

This bumps `project.yml`, runs `dist.sh` (build → notarize → DMG), signs the
DMG with the Sparkle EdDSA key (`tools/sparkle/sign_update`), prepends an
entry to `appcast.xml`, then tags, pushes, and publishes a GitHub Release with
the DMG attached. Existing installs pick up the update automatically within
a day, or immediately via the manual check.

The Sparkle private signing key lives only in this machine's Keychain (never
in the repo); `tools/sparkle/` just holds the small `generate_keys` /
`sign_update` / `generate_appcast` CLI binaries so `release.sh` doesn't depend
on a local Sparkle checkout existing at a particular path.
