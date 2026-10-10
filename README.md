# RecordStudio

A screen recorder for macOS that makes polished product videos. Record your screen, a window or an area, and RecordStudio zooms in on your clicks, frames the video on a background and moves the camera smoothly.

Everything stays on your Mac. There are no accounts, no telemetry and no uploads.

**Website:** [kasapovicc.github.io/RecordStudio](https://kasapovicc.github.io/RecordStudio/)

## What it does

- **Records** a screen, a window or an area, with your microphone, the system sound and your webcam. A teleprompter can show your notes while you record.
- **Edits** without touching the original: automatic zooms, trims, cuts, speed changes, captions made on your Mac, text, arrows, blur, music and chapters.
- **Exports** MP4, HEVC, WebM or GIF, with subtitles, a transcript and a poster image if you want them.

## Install

1. Download the latest `RecordStudio-<version>.dmg` from [Releases](https://github.com/kasapovicc/RecordStudio/releases/latest).
2. Open it. In the window that appears, drag RecordStudio onto the Applications folder framed on the right.
3. Open RecordStudio. A short Welcome window asks for the permissions it needs.

RecordStudio needs macOS 26 (Tahoe) or later, on Apple silicon or Intel. It checks GitHub for new versions once a day and installs them when you agree. You can turn this off in **Settings › Updates**.

## Getting started

1. **Record.** Press ⌘N, or ⌃⌥⌘R from any app. Pick **Screen**, **Window** or **Area** in the bar that appears, then press **Record**.
2. **Stop.** Press ⌃⌥⌘S from any app, or **■ Stop** on the small pill. The recording opens in the editor.
3. **Edit.** Zooms are already there from your clicks. A **Next steps** card in the corner walks you through trimming, captions and text.
4. **Export.** Press ⌘E, pick a format and press **Export**.

To try the editor without recording, use **Help › Open Sample Project**. **Help › Keyboard Shortcuts** (⌘/) lists every shortcut, and you can change them in **Settings › Shortcuts**.

## Permissions

macOS asks for each one the first time it is needed. **Settings › Permissions** shows what is allowed.

| Permission | What for |
| --- | --- |
| Screen & System Audio Recording | The recording itself. Required. |
| Microphone | Your voice |
| Camera | The webcam bubble |
| Input Monitoring | Showing the shortcuts you press in the video |
| Accessibility | Resizing a window to a video size before recording it |
| Speech Recognition | Captions and transcripts, made on your Mac |

After you allow Screen Recording, RecordStudio has to relaunch. It offers to do that for you.

## Where your files are

Everything is in `~/Movies/RecordStudio/`: the library database, each recording's folder and your exports. The original recording is never changed, and edits save automatically.

To back it up, quit the app and copy the folder. Time Machine includes it.

## Reporting issues

Found a bug or have an idea? [Open an issue](https://github.com/kasapovicc/RecordStudio/issues/new) on GitHub. Please include:

- your macOS version and the RecordStudio version from **RecordStudio › About RecordStudio**;
- what you did, what you expected, and what happened instead;
- a screenshot or a short screen recording, if it shows the problem.

Check the recording for anything private before you attach it. Your recordings never leave your Mac unless you share them.

## Building from source

You need macOS 26 and Xcode 26 (or its Command Line Tools: `xcode-select --install`). WebM export also needs `brew install ffmpeg`. No packages are downloaded: the app uses only Apple frameworks and the system SQLite.

```sh
make run     # build, sign and open build/RecordStudio.app
make test    # run the tests (swift test)
```

`make` signs with your *Apple Development* certificate if you have one, so macOS keeps the Screen Recording permission across rebuilds. Without one it signs ad hoc, and macOS asks again after each build.

### Project layout

```
Sources/RecordCore     pure logic, Foundation only: zooms, camera path, sizes, captions, shortcuts, tips, update versions, audio clean-up
Sources/RecordKit      capture, rendering, export, library storage, projects, import
Sources/RecordStudio   the SwiftUI and AppKit app: library, editor, inspector, timeline, record bar, settings, updater
Tests/                 RecordCoreTests (logic) and RecordKitTests (rendering and end-to-end exports)
Resources/             app icon, Info.plist, entitlements and the sample project
```

The preview and the export draw every frame with the same `FrameRenderer`, so what you see in the editor is what you get.

### Website

The landing page is plain HTML, CSS and JS in `site/`, with no build step. `python3 -m http.server -d site` serves it
locally. `.github/workflows/pages.yml` publishes it to GitHub Pages when `site/` changes on `main`. Its screenshots and
videos come from the sample project only.

### Configuration (.env)

`.env.example` lists the variables: `RECORD_STUDIO_DIR` moves the library folder and `FFMPEG_PATH` points at ffmpeg. `.env` is git-ignored.



## Known limitations

- A window recording assumes the window does not move while you record.
- Noise reduction treats any sound that never stops as noise, so a recording with music all the way through gets the music turned down too.

## Licence

RecordStudio is released under the [MIT License](LICENSE), © 2026 Studio Alto. The RecordStudio name and icon aren't covered by the licence: a fork needs its own name and icon.
