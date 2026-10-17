import AVFoundation
import Observation
import RecordCore
import RecordKit
import SwiftUI
import UniformTypeIdentifiers

/// The inspector's overall settings, grouped by what you're doing. Each zoom, callout, annotation and the like is edited
/// by selecting it instead.
enum InspectorTab: String, CaseIterable, Identifiable {
    case look, cursorZoom, overlays, sound
    var id: String { rawValue }
    var name: String { ["look": "Look", "cursorZoom": "Cursor & Zoom", "overlays": "Overlays", "sound": "Sound"][rawValue]! }
}

/// A piece of one timeline lane between split points: `segment` indexes `Edits.keptSegments`.
struct TimelinePart: Equatable {
    enum Lane: Equatable { case clip, sound(SoundSource) }
    var lane: Lane
    var segment: Int
}

/// The Export sheet's choices. Remembered per recording, and the last ones used start any recording not exported yet.
struct ExportSettings: Codable, Equatable {
    var format = ExportFormat.mp4
    var gif = GIFOptions()
    var resolution = ExportResolution.p1080
    var quality = ExportQuality.high
    var folder = Paths.exports.path
    var extras: ExportExtras = [.subtitles, .transcript]

    static func key(_ id: String) -> String { "export.\(id)" }
    static let lastKey = "export.last"

    static func load(for id: String, _ defaults: UserDefaults = .standard) -> ExportSettings {
        for key in [key(id), lastKey] {
            if let data = defaults.data(forKey: key), let s = try? JSONDecoder().decode(ExportSettings.self, from: data) { return s }
        }
        return ExportSettings()
    }

    func save(for id: String, _ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key(id))
        defaults.set(data, forKey: Self.lastKey)
    }

    /// The extra files that can be saved in this format with `edits`: GIFs have no sound, and subtitles need captions.
    func availableExtras(for edits: Edits) -> ExportExtras {
        var a = ExportExtras.all
        if format == .gif { a.subtract([.transcript, .subtitles]) }
        if edits.captions?.srt != true { a.remove(.subtitles) }
        return a
    }
}

extension ExportJob {
    /// Exporting `rec` with `edits` and the Export sheet's `settings`, from the editor or from the library.
    init(_ rec: Recording, edits: Edits, cursor: [CursorSample], title: String, name: String, settings o: ExportSettings) {
        self.init(source: URL(fileURLWithPath: rec.path), width: rec.width, height: rec.height, duration: rec.duration, fps: rec.fps,
                  title: title,
                  createdAt: Date(timeIntervalSince1970: Double(rec.createdAt) / 1000), edits: edits, cursor: cursor,
                  format: o.format, outDir: URL(fileURLWithPath: o.folder), name: name,
                  extras: o.extras.intersection(o.availableExtras(for: edits)),
                  camera: rec.hasCamera ? URL(fileURLWithPath: rec.cameraPath) : nil, cameraOffset: rec.cameraOffset,
                  windowCornerPx: rec.windowCornerPx, gif: o.gif, resolution: o.resolution, quality: o.quality,
                  systemAudio: rec.hasSystemAudio ? URL(fileURLWithPath: rec.systemAudioPath) : nil, systemAudioOffset: rec.systemAudioOffset,
                  cursorImages: rec.cursorImages, keys: rec.keys)
    }
}

enum ExportState: Equatable {
    case idle
    case working(String, Double?)
    case done(video: String, place: String, transcriptError: String?)
    case failed(String)
}

/// One open recording: its edits, the preview player (rendering the same frames as export), autosave and export.
@MainActor @Observable
final class EditorModel {
    let rec: Recording
    var edits: Edits {
        didSet {
            guard edits != oldValue else { return }
            if !restoring {
                history.record(oldValue, at: ProcessInfo.processInfo.systemUptime, drag: dragOrigin)
                TipStore.shared.noteEdit(from: oldValue, to: edits)
            }
            editsChanged()
        }
    }
    /// Undo and redo, for this window only; starts empty when the recording is opened.
    private(set) var history = EditHistory()
    @ObservationIgnored private var restoring = false
    private(set) var cursor: [CursorSample]
    /// The cursor's shapes when it's redrawn rather than baked into the video.
    let cursorImages: [CursorImage]
    /// Shortcuts pressed while recording; empty when they weren't captured.
    let keys: [ShortcutPress]
    var title: String { didSet { if title != oldValue { scheduleSave() } } }
    var exportSettings: ExportSettings { didSet { if exportSettings != oldValue { exportSettings.save(for: rec.id) } } }
    /// The exported file's name, without its extension. Starts as the title.
    var exportName = ""
    var showExport = false
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    var time = 0.0
    private(set) var playing = false
    // One thing is selected at a time, so ⌫ deletes what was clicked last.
    var selectedZoom: Int? {
        didSet {
            if selectedZoom != nil { clearSelection(but: \.selectedZoom); TipStore.shared.done(.zooms, seen: .zoom) }
            if selectedZoom != oldValue { refreshPreview() } // the preview leaves a selected zoom out; see `refreshPreview`
        }
    }
    var selectedAnnotation: Int? { didSet { if selectedAnnotation != nil { clearSelection(but: \.selectedAnnotation) } } }
    var selectedCallout: Int? { didSet { if selectedCallout != nil { clearSelection(but: \.selectedCallout) } } }
    var selectedMarker: Int? { didSet { if selectedMarker != nil { clearSelection(but: \.selectedMarker) } } }
    var selectedCaption: Int? { didSet { if selectedCaption != nil { clearSelection(but: \.selectedCaption) } } }
    /// The music clip as a whole; a piece of it can be selected with it, in `selectedPart` (see `selectMusic`).
    var selectedMusic = false { didSet { if selectedMusic { clearSelection(but: nil) } } }
    private func clearSelection(but keep: ReferenceWritableKeyPath<EditorModel, Int?>?) {
        for k in [\EditorModel.selectedZoom, \.selectedAnnotation, \.selectedCallout, \.selectedMarker, \.selectedCaption] where k != keep && self[keyPath: k] != nil {
            self[keyPath: k] = nil
        }
        if keep != nil { selectedMusic = false }
        // Selecting the music keeps a clicked piece of it; `selectMusic` sets the new one.
        if keep != nil || selectedPart?.lane != .sound(.music) { selectedPart = nil }
    }
    /// The chapter marker whose name is being edited, in its popover on the timeline.
    var renamingMarker: Int?
    /// Selects nothing, so the inspector shows its tabs again.
    /// When a key was last pressed in the editor window, so what it changes can skip the animation a click would get.
    @ObservationIgnored var keyPressedAt = 0.0

    func deselect() {
        (selectedZoom, selectedAnnotation, selectedCallout, selectedMarker, selectedCaption, selectedPart) = (nil, nil, nil, nil, nil, nil)
        selectedMusic = false
    }

    /// A click on the music at recording time t selects it, and once the clip is split, the piece under the click too.
    func selectMusic(at t: Double) {
        selectedMusic = true
        let segments = edits.keptSegments
        selectedPart = segments.count > 1 ? segments.firstIndex { t >= $0.start && t <= $0.end }.map { TimelinePart(lane: .sound(.music), segment: $0) } : nil
    }

    /// One piece between split points on one lane, selected so ⌫ removes just that piece (see `removePart`).
    var selectedPart: TimelinePart? {
        // A clicked piece of the music going (a split, a cut, an inserted clip) takes the music's selection with it,
        // so ⌫ or the trash button never ends up deleting the whole music.
        didSet { if selectedPart == nil, oldValue?.lane == .sound(.music) { selectedMusic = false } }
    }
    var tab: InspectorTab = .look
    /// The groups with something in them for this recording: Overlays needs a webcam, microphone sound to caption, or
    /// shortcuts pressed while recording.
    var tabs: [InspectorTab] { InspectorTab.allCases.filter { $0 != .overlays || edits.camera != nil || rec.hasAudio || !keys.isEmpty } }
    /// The wallpaper, image and gradient the Background tab last switched away from, for switching back.
    var backgroundMemory = BackgroundMemory()
    /// The look last applied or saved in this editor, so a change after it shows as "(edited)" with Update.
    var appliedLook: String?
    /// What each inspector group's Reset puts back: the settings a new recording starts with.
    @ObservationIgnored private(set) lazy var defaults = rec.startingEdits(cursor: [])
    var showInspector = true
    /// The preview has drawn its first frame (or couldn't load), so the editor around it can show. Never goes back.
    var previewReady = false
    var inspectorFit = InspectorFit()
    /// The Pauses popover, also opened from Clip › Remove Pauses….
    var showPauses = false
    var cropping = false { didSet { refreshPreview() } }
    var export: ExportState = .idle
    private(set) var saveState = "Saved"
    /// Work under way in the editor ("Inserting “Demo.mov”…"), shown with a spinner until it's done.
    var progress: String?
    /// Something finished, or worth knowing; it goes away by itself.
    var toast: Toast?

    /// For the timeline: microphone and system audio loudness every `VoiceActivity.window` seconds, and the camera
    /// file's length. Read once, in the background.
    private(set) var micLevels: [Double] = []
    private(set) var systemLevels: [Double] = []
    private(set) var cameraDuration: Double?
    /// When you're speaking in this recording, for ducking music and finding pauses. Measured once, in the background;
    /// nil until then.
    private(set) var voice: [ClosedRange<Double>]?
    /// The pauses panel's settings while it's open, so the timeline can show what it would take out.
    var pausePanel: PauseOptions?

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private var item: AVPlayerItem?
    @ObservationIgnored private var sources: Sources?
    /// What `sources` was built for; when the edits differ, the player is rebuilt.
    @ObservationIgnored private var loadedKey: SourcesKey?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var projectTask: Task<Void, Never>?
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?
    /// Edits as they were when a timeline drag began; drags apply offsets to this.
    @ObservationIgnored var dragOrigin: Edits?
    /// Where the item being dragged has snapped to, shown as a line on the timeline.
    var snapGuide: Double?
    /// How many times wider than the window the timeline is drawn: 1 fits the whole recording. The timeline sets the most
    /// it can be for its width.
    var timelineZoom = 1.0
    var maxTimelineZoom = 1.0

    var problems: [String] { validateEdits(edits, duration: rec.duration) }
    /// The timeline's length: the recording with any inserted clips (see `InsertedClip`). Every time in the edits, and
    /// `time`, is on it.
    var duration: Double { edits.timelineDuration(rec.duration) }
    var size: OutputSize { outputSize(width: rec.width, height: rec.height, edits) }

    init(rec: Recording) {
        self.rec = rec
        title = rec.title
        exportSettings = ExportSettings.load(for: rec.id)
        let samples = rec.cursorSamples
        cursor = samples
        cursorImages = rec.cursorImages
        keys = rec.keys
        var fresh = rec.edits == nil // starting edits are saved straight away
        do { edits = try rec.openingEdits(cursor: samples) } catch {
            edits = rec.startingEdits(cursor: samples)
            fresh = true
            Studio.shared.error = Problem("Couldn’t read this recording’s edits", "They were unreadable, so it opens without them.")
        }

        player.actionAtItemEnd = .pause
        loadSources()
        TipStore.shared.state.opens += 1
        Task { [weak self, rec] in
            let mic = await Task.detached { (try? await AudioLevels.read(URL(fileURLWithPath: rec.path), window: VoiceActivity.window)) ?? [] }.value
            guard let self else { return }
            micLevels = mic
            voice = VoiceActivity.ranges(levels: mic)
            if edits.audio?.duck == true { refreshPreview() }
        }
        if rec.hasSystemAudio {
            Task { [weak self, rec] in
                let levels = await Task.detached {
                    (try? await AudioLevels.read(URL(fileURLWithPath: rec.systemAudioPath), window: VoiceActivity.window)) ?? []
                }.value
                self?.systemLevels = levels
            }
        }
        if rec.hasCamera {
            Task { [weak self, rec] in
                let d = try? await AVURLAsset(url: URL(fileURLWithPath: rec.cameraPath)).load(.duration).seconds
                self?.cameraDuration = d
            }
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        // The time observer stops firing once the player stops (end of clip), so follow its state directly.
        statusObserver = player.observe(\.timeControlStatus) { [weak self] p, _ in
            let stopped = p.timeControlStatus == .paused
            Task { @MainActor in if stopped { self?.playing = false } }
        }
        time = edits.trim.start
        refreshPreview()
        if fresh { scheduleSave() }
    }

    func close() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        statusObserver = nil
        observer = nil
        saveTask?.cancel()
        save() // never lose the last edit
    }

    // MARK: Playback

    // The player plays the edited video, as the export does: only the kept parts, back to back, each at its speed, so
    // it runs straight through cuts and speed changes. Its time is output time; `time` is timeline time.

    /// The time map the player's item was built with: output time ↔ recording time.
    private var playerMap: [Trim] { sources?.segments ?? edits.timeMap }

    private func tick(_ t: Double) {
        guard t.isFinite else { return }
        time = outputToSource(playerMap, t)
    }

    func togglePlay() { playing ? pause() : play() }

    /// J and L: play backward or forward, twice as fast each time it's pressed again, up to 8×.
    func shuttle(forward: Bool) {
        let sign: Float = forward ? 1 : -1
        if !forward, item?.canPlayReverse == false { return }
        let rate = playing && player.rate * sign > 0 ? min(abs(player.rate) * 2, 8) : 1
        if !playing { play() }
        player.rate = sign * rate
    }

    /// Moves the playhead by d seconds of the edited video, so a frame is a frame even in sped-up parts.
    func step(by d: Double) {
        pause()
        let map = edits.timeMap
        seek(outputToSource(map, min(outputDuration(map), max(0, sourceToOutput(map, time) + d))))
    }

    /// ↑ / ↓: the previous or next split, item edge or chapter.
    func jumpToEdit(forward: Bool) {
        let points = edits.editPoints
        if let t = forward ? points.first(where: { $0 > time + 0.005 }) : points.last(where: { $0 < time - 0.005 }) { seek(t) }
    }

    /// ⌘+ / ⌘−: zooms the timeline in or out by `factor`, within what it allows.
    func zoomTimeline(by factor: Double) {
        timelineZoom = min(maxTimelineZoom, max(1, timelineZoom * factor))
    }

    func play() {
        let map = playerMap
        if sourceToOutput(map, time) >= outputDuration(map) - 0.05 || time < edits.trim.start { seek(edits.trim.start) }
        player.play()
        playing = true
        TipStore.shared.done(.watch)
    }

    func pause() {
        player.pause()
        playing = false
    }

    /// Shows timeline time t. In a cut, or outside the trim, that's where the video carries on.
    func seek(_ t: Double) {
        let c = min(duration, max(0, t))
        time = c
        player.seek(to: CMTime(seconds: sourceToOutput(playerMap, c), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: Preview

    /// The edits the player's item depends on: the extra audio file and its placement, and what plays at which speed.
    private struct SourcesKey: Equatable {
        var audio: String?
        var map: [Trim]
        var mic: MicCleanup?
        var clips: [InsertedClip]
        var overlays: [String]
    }

    private var sourcesKey: SourcesKey {
        SourcesKey(audio: edits.audio.map { "\($0.path)|\($0.placement)" }, map: edits.timeMap, mic: edits.micCleanup.flatMap { $0.isOn ? $0 : nil },
                   clips: edits.allClips.map { var c = $0; c.volume = nil; return c }, // volume is only the mix
                   overlays: edits.videoOverlays.map { "\($0.video?.path ?? "")|\($0.video?.at ?? 0)|\($0.start)|\($0.end)" })
    }

    private func editsChanged() {
        if sourcesKey != loadedKey { loadSources(after: .milliseconds(150)) } else { refreshPreview() }
        scheduleSave()
    }

    /// Screen, camera, system audio and any extra audio combined into the edited video, in a fresh player item at the
    /// current time. `after` lets a drag settle first, so the player is rebuilt once rather than at every step.
    private func loadSources(after delay: Duration = .zero) {
        let rec = rec, audio = edits.audio, key = sourcesKey, overlays = edits.videoOverlays
        loadedKey = key
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
            }
            // Until the cleaned microphone is ready the preview keeps playing what it has; if it can't be made, the original.
            var mic: CleanMic?
            do { mic = try await self?.cleanMic(key.mic) } catch {
                if !Task.isCancelled { Studio.shared.error = Problem("Couldn’t clean up the microphone", "\(error.localizedDescription) The original sound plays instead.") }
            }
            do {
                let src = try await Sources.load(screen: URL(fileURLWithPath: rec.path),
                                                 camera: rec.hasCamera ? URL(fileURLWithPath: rec.cameraPath) : nil, offset: rec.cameraOffset,
                                                 music: audio, system: rec.hasSystemAudio ? URL(fileURLWithPath: rec.systemAudioPath) : nil,
                                                 systemOffset: rec.systemAudioOffset, mic: mic, clips: key.clips, overlays: overlays, segments: key.map)
                guard let self, !Task.isCancelled, sourcesKey == key else { return } // superseded by a newer edit
                let wasPlaying = playing, at = time
                sources = src
                let item = AVPlayerItem(asset: src.asset)
                item.audioTimePitchAlgorithm = .spectral // sped-up or slowed parts keep their pitch, as in the export
                self.item = item
                player.replaceCurrentItem(with: item)
                seek(at)
                if wasPlaying { player.play() }
                refreshPreview()
            } catch {
                Studio.shared.error = Problem("Couldn’t play this recording", error.localizedDescription)
                self?.previewReady = true // nothing to wait for; show the rest of the editor
            }
        }
    }

    /// True while the cleaned microphone is being made, for the Audio tab.
    private(set) var cleaningMic = false
    /// The one making it. It's shared rather than tied to `loadTask`, which every edit cancels, so a trim while it
    /// works doesn't start it over.
    @ObservationIgnored private var micWork: (cleanup: MicCleanup, task: Task<CleanMic?, Error>)?

    private func cleanMic(_ cleanup: MicCleanup?) async throws -> CleanMic? {
        guard let cleanup else { return nil }
        if micWork?.cleanup != cleanup {
            micWork?.task.cancel()
            let screen = URL(fileURLWithPath: rec.path), folder = URL(fileURLWithPath: rec.dir)
            micWork = (cleanup, Task { try await MicCleaner.file(for: screen, in: folder, cleanup) })
        }
        guard let task = micWork?.task else { return nil }
        cleaningMic = true
        defer { if micWork?.task == task { cleaningMic = false } }
        return try await task.value
    }

    /// Adds an audio file (copied into the recording's folder) from the playhead, or replaces the current one.
    func setAudio(from url: URL) async throws {
        let ext = url.pathExtension.lowercased()
        guard AudioTrack.extensions.contains(ext) else { throw StudioError.message("Choose an M4A, MP3, WAV, AIFF, CAF or AAC file.") }
        let dest = URL(fileURLWithPath: rec.dir).appending(path: "audio-\(UUID().uuidString.prefix(8)).\(ext)")
        try FileManager.default.copyItem(at: url, to: dest)
        let length = try await AVURLAsset(url: dest).load(.duration).seconds
        guard length.isFinite, length > 0.1 else { throw StudioError.message("That file has no sound to play.") }
        let at = round2(min(time, max(0, duration - 0.5)))
        var track = AudioTrack(path: dest.path, fileDuration: length, at: at, length: round2(min(length, duration - at)))
        if let old = edits.audio { (track.volume, track.fadeIn, track.fadeOut, track.duck) = (old.volume, old.fadeIn, old.fadeOut, old.duck) }
        edits.audio = track
        tab = .sound
    }

    /// Where the camera is at timeline time t, for placing things that live in recording space (blur boxes).
    func camera(at t: Double) -> CameraPoint { renderer?.camera(at: t) ?? cameraAt(cameraPath(cursor, edits, duration: rec.duration), t) }

    /// Where the caption showing at t sits on the canvas (normalized, top-left origin); nil when none shows.
    func captionBox(at t: Double) -> CGRect? { renderer?.captionBox(at: t) }

    /// An annotation's box on the canvas. A blur's box is kept in recording space, so it's mapped through the crop and
    /// the camera as it is now; the others are on the canvas already.
    func onCanvas(_ a: Annotation) -> Annotation {
        guard a.kind == .blur else { return a }
        let cam = camera(at: time)
        let p = canvasPoint(Point(x: a.x, y: a.y), edits, size, camera: cam)
        let q = canvasPoint(Point(x: a.x + a.w, y: a.y + a.h), edits, size, camera: cam)
        var b = a
        (b.x, b.y, b.w, b.h) = (p.x, p.y, q.x - p.x, q.y - p.y)
        return b
    }

    /// Back from `onCanvas`, for saving.
    func inRecording(_ b: Annotation, like a: Annotation) -> Annotation {
        guard a.kind == .blur else { return b }
        let cam = camera(at: time)
        let p = sourcePoint(Point(x: b.x, y: b.y), edits, size, camera: cam)
        let q = sourcePoint(Point(x: b.x + b.w, y: b.y + b.h), edits, size, camera: cam)
        var c = b
        (c.x, c.y, c.w, c.h) = (p.x, p.y, q.x - p.x, q.y - p.y)
        return c
    }

    /// Moves the selected callout or annotation by dx, dy (normalized to the canvas), keeping a callout on it.
    /// False when neither is selected.
    @discardableResult
    func moveSelection(dx: Double, dy: Double) -> Bool {
        if let i = selectedCallout, edits.callouts.indices.contains(i) {
            edits.callouts[i].x = min(1, max(0, edits.callouts[i].x + dx))
            edits.callouts[i].y = min(1, max(0, edits.callouts[i].y + dy))
            return true
        }
        if let i = selectedAnnotation, edits.allAnnotations.indices.contains(i) {
            let a = edits.allAnnotations[i]
            var b = onCanvas(a)
            (b.x, b.y) = (b.x + dx, b.y + dy)
            edits.allAnnotations[i] = inRecording(b, like: a)
            return true
        }
        return false
    }

    /// The renderer behind the preview, for the camera's path; nil while cropping, when the camera isn't shown.
    @ObservationIgnored private var renderer: FrameRenderer?

    /// Rebuilds the video composition for the current edits. Coalesced so slider drags don't queue up work.
    private func refreshPreview() {
        previewTask?.cancel()
        // While cropping, show the raw screen frame: same renderer with every effect off.
        var shown = self.edits
        if cropping {
            shown = Edits(trim: self.edits.trim, padding: 0, cursorHighlight: false)
            shown.clips = self.edits.clips // the player's timeline still has them
        }
        // A selected zoom is left out, so the whole frame shows with the zoom's area drawn over it to drag.
        if let z = selectedZoom, shown.zooms.indices.contains(z) { shown.zooms.remove(at: z) }
        let edits = shown
        let cursor = cursor, rec = rec, cursorImages = cropping ? [] : cursorImages, keys = cropping ? [] : keys
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            guard let self, !Task.isCancelled, let item, let sources else { return }
            let renderer = await Task.detached {
                FrameRenderer(edits: edits, cursor: cursor, sourceWidth: rec.width, sourceHeight: rec.height, duration: rec.duration,
                              windowCornerPx: rec.windowCornerPx, cursorImages: cursorImages, keys: keys)
            }.value
            guard !Task.isCancelled, let comp = try? await Composition.make(sources, renderer: renderer, fps: rec.fps), !Task.isCancelled else { return }
            self.renderer = cropping ? nil : renderer
            item.videoComposition = comp
            item.audioMix = AudioMixer.make(sources, music: edits.audio, voice: voice ?? [], mic: edits.micVolume ?? 1, system: edits.systemVolume ?? 1,
                                            silenced: edits.silenced ?? [], clips: edits.allClips, overlays: edits.videoOverlays)
            if !playing { seek(time) } // redraw the paused frame
        }
    }

    // MARK: Saving (edits live in SQLite; the original file is never touched)

    private func scheduleSave() {
        saveState = "Saving…"
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { saveState = "Add a title to save"; return }
        do {
            guard let saved = try Studio.shared.library?.saveEdits(id: rec.id, title: name, edits: edits) else { return }
            saveState = "Saved"
            if saved.editedAt != lastProjectEdit { lastProjectEdit = saved.editedAt; scheduleProjectSave(title: name) }
            // Kept in step, so the gallery's Recently edited is current and reopening shows these edits.
            if let i = Studio.shared.recordings.firstIndex(where: { $0.id == rec.id }) {
                (Studio.shared.recordings[i].title, Studio.shared.recordings[i].edits, Studio.shared.recordings[i].editedAt) = (name, saved.edits, saved.editedAt)
            }
        } catch {
            saveState = "Not saved"
            Studio.shared.error = Problem("Couldn’t save your edits", error.localizedDescription)
        }
    }

    /// The edit time the project file was last written for, so saving unchanged edits doesn't rewrite it.
    @ObservationIgnored private var lastProjectEdit: Int64?

    /// Keeps this recording's project file (see `Project.autosave`) in step with its edits, once they've settled for a
    /// few seconds, in the background. It outlives the editor, so closing right after an edit still writes it.
    // ponytail: rewrites the whole file each time; quitting within the delay leaves the previous version.
    private func scheduleProjectSave(title: String) {
        guard let root = Studio.shared.library?.root else { return }
        projectTask?.cancel()
        let rec = rec, edits = edits
        projectTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            do { try await Project.autosave(rec, title: title, edits: edits, root: root) }
            catch { Studio.shared.error = Problem("Couldn’t update the project file", error.localizedDescription) }
        }
    }

    // MARK: Editing helpers

    func undo() { if let e = history.undo(edits) { restore(e) } }
    func redo() { if let e = history.redo(edits) { restore(e) } }

    /// Puts back edits from the history: previewed and saved like any edit. Selections may point at what changed, so
    /// they're cleared.
    private func restore(_ e: Edits) {
        restoring = true
        edits = e
        restoring = false
        (selectedZoom, selectedAnnotation, selectedCallout, selectedMarker, selectedCaption, selectedPart, renamingMarker) = (nil, nil, nil, nil, nil, nil, nil)
        selectedMusic = false
    }

    func addZoom() {
        // With no cursor to follow (an imported video), it's pinned to the middle until moved.
        let z = Zoom(start: round2(time), end: round2(min(duration, time + 3)), scale: 1.8, focus: cursor.isEmpty ? Point(x: 0.5, y: 0.5) : nil)
        edits.zooms.append(z)
        edits.zooms.sort { $0.start < $1.start }
        selectedZoom = edits.zooms.firstIndex(of: z)
        tab = .cursorZoom
    }

    func selectZoom(_ i: Int?) {
        selectedZoom = i
        guard let i, edits.zooms.indices.contains(i) else { return }
        tab = .cursorZoom
        let z = edits.zooms[i]
        seek(z.start + min(1, (z.end - z.start) / 3)) // land on the fully zoomed part
    }

    func removeZoom(_ i: Int) {
        guard edits.zooms.indices.contains(i) else { return }
        edits.zooms.remove(at: i)
        selectedZoom = nil
    }

    /// The piece of the clip a speed change applies to: the one given, the selected one, or the one under the playhead.
    func speedPiece(_ i: Int? = nil) -> Int? {
        if let i { return i }
        if let p = selectedPart, p.lane == .clip { return p.segment }
        return edits.keptSegments.firstIndex { time >= $0.start && time < $0.end }
    }

    /// Plays a piece of the clip (see `speedPiece`) at `speed`, and everything with it.
    func setSpeed(_ speed: Double, piece: Int? = nil) {
        let s = edits.keptSegments
        guard let i = speedPiece(piece), s.indices.contains(i) else { toast = Toast(text: "Move the playhead onto the clip to change its speed."); return }
        edits.setSpeed(speed, from: s[i].start, to: s[i].end)
    }

    /// The long pauses `o` finds in what plays now: what `removePauses` would take out.
    func pauses(_ o: PauseOptions) -> [Trim] { edits.pauses(voice: edits.timelineRanges(voice ?? []), o) }

    /// Cuts or speeds up every long pause, as one undo step.
    func removePauses(_ o: PauseOptions) {
        edits.removePauses(voice: edits.timelineRanges(voice ?? []), o)
        selectedPart = nil // segment indices moved
    }

    /// Adds a chapter marker at the playhead and opens its name for typing. On an existing marker, opens that one.
    func addMarker() {
        let t = round2(time)
        if let i = edits.allMarkers.firstIndex(where: { abs($0.t - t) < 0.1 }) { selectedMarker = i; renamingMarker = i; return }
        let m = Marker(t: t, name: "Chapter \(edits.allMarkers.count + 1)")
        edits.allMarkers.append(m)
        selectedMarker = edits.allMarkers.firstIndex(of: m)
        renamingMarker = selectedMarker
    }

    func removeMusic() {
        edits.audio = nil
        deselect()
    }

    func removeMarker(_ i: Int) {
        guard edits.allMarkers.indices.contains(i) else { return }
        edits.allMarkers.remove(at: i)
        (selectedMarker, renamingMarker) = (nil, nil)
    }

    /// Whether captions show in the preview and export. The first time they're turned on, the recording's speech is
    /// transcribed on this Mac to make them; after that, off only hides them, keeping any edited lines.
    var showCaptions: Bool {
        get { edits.captions?.visible == true || transcribing }
        set {
            if edits.captions == nil { if newValue { makeCaptions() } } else { edits.captions?.visible = newValue }
        }
    }
    private(set) var transcribing = false

    /// Transcribes the recording's speech into caption lines. Again, it replaces the lines but keeps their look; ⌘Z
    /// brings the old lines back.
    func makeCaptions() {
        guard !transcribing else { return }
        transcribing = true
        Task { [weak self, rec] in
            do {
                let words = try await Transcriber.words(URL(fileURLWithPath: rec.path))
                guard let self else { return }
                // Words are heard at recording time; on the timeline they move past any inserted clips.
                let lines = captionLines(words.map { CaptionWord($0.text, start: self.edits.timelineTime($0.start), end: self.edits.timelineTime($0.end)) })
                if lines.isEmpty { self.toast = Toast(text: "No speech was found in this recording, so there are no captions to show.") }
                else if self.edits.captions == nil { self.edits.captions = Captions(lines: lines) }
                else { edits.captions?.lines = lines; edits.captions?.visible = true; selectedCaption = nil }
            } catch {
                Studio.shared.error = Problem("Couldn’t make captions", error.localizedDescription)
            }
            self?.transcribing = false
        }
    }

    /// The caption line to split: the selected one, or the one under the playhead.
    var splittableCaption: Int? {
        guard let lines = edits.captions?.lines else { return nil }
        if let i = selectedCaption, lines.indices.contains(i), time > lines[i].start + 0.05, time < lines[i].end - 0.05 { return i }
        return lines.firstIndex { time > $0.start + 0.05 && time < $0.end - 0.05 && $0.text.contains(" ") }
    }

    /// Splits a caption line at the playhead (see `splittableCaption`), sharing its words by time.
    func splitCaption() {
        guard let i = splittableCaption, edits.captions?.split(i, at: round2(time)) == true else { return }
        selectedCaption = i + 1
    }

    func selectCaption(_ i: Int) {
        guard let lines = edits.captions?.lines, lines.indices.contains(i) else { return }
        let l = lines[i]
        selectedCaption = i
        tab = .overlays
        if time < l.start || time >= l.end { seek(l.start) }
    }

    func addCallout() {
        edits.callouts.append(Callout(text: "New callout", start: round2(time), end: round2(min(duration, time + 3)), x: 0.05, y: 0.06))
        selectedCallout = edits.callouts.count - 1
    }

    /// Adds an annotation at the playhead for 3 seconds, near the middle of the frame, and selects it.
    /// `aspect` is an image's width ÷ height, so it's placed without stretching.
    func addAnnotation(_ kind: Annotation.Kind, image: String? = nil, aspect: Double = 1, pixelate: Bool = false) {
        let start = round2(min(time, max(0, duration - 0.5))), end = round2(min(duration, start + 3))
        let a: Annotation
        switch kind {
        case .arrow:
            a = Annotation(kind: .arrow, start: start, end: end, x: 0.38, y: 0.38, w: 0.12, h: 0.12)
        case .rectangle, .ellipse:
            a = Annotation(kind: kind, start: start, end: end, x: 0.35, y: 0.4, w: 0.3, h: 0.2)
        case .image:
            let w = 0.25, h = min(0.8, w * Double(size.width) / Double(max(1, size.height)) / max(0.1, aspect))
            a = Annotation(kind: .image, start: start, end: end, x: 0.5 - w / 2, y: 0.5 - h / 2, w: w, h: h, image: image)
        case .video:
            return // see `addVideoOverlay`
        case .blur:
            // Over the middle of what's on screen now, zoomed or not; it's kept in recording space from then on.
            let cam = camera(at: start)
            let a0 = sourcePoint(Point(x: 0.38, y: 0.4), edits, size, camera: cam), b0 = sourcePoint(Point(x: 0.62, y: 0.6), edits, size, camera: cam)
            var b = Annotation(kind: .blur, start: start, end: end, x: a0.x, y: a0.y, w: b0.x - a0.x, h: b0.y - a0.y, fade: 0.3)
            b.pixelate = pixelate ? true : nil
            a = b
        }
        edits.allAnnotations.append(a)
        selectedAnnotation = edits.allAnnotations.count - 1
    }

    func selectAnnotation(_ i: Int) {
        guard edits.allAnnotations.indices.contains(i) else { return }
        selectedAnnotation = i
        let a = edits.allAnnotations[i]
        if annotationOpacity(a, at: time) == 0 { seek(a.start + min(0.5, (a.end - a.start) / 2)) } // show it, past any fade-in
    }

    func removeAnnotation(_ i: Int) {
        guard edits.allAnnotations.indices.contains(i) else { return }
        edits.allAnnotations.remove(at: i)
        if let s = selectedAnnotation { selectedAnnotation = s == i ? nil : (s > i ? s - 1 : s) }
    }

    /// Runs an editor shortcut.
    func perform(_ action: ShortcutAction) {
        switch action {
        case .play: togglePlay()
        case .setIn: setTrimStart()
        case .setOut: setTrimEnd()
        case .addZoom: addZoom()
        case .delete:
            if let i = selectedZoom { removeZoom(i) }
            else if let i = selectedAnnotation { removeAnnotation(i) }
            else if let i = selectedCallout, edits.callouts.indices.contains(i) { edits.callouts.remove(at: i); selectedCallout = nil }
            else if let i = selectedMarker { removeMarker(i) }
            else if let i = selectedCaption, edits.captions?.lines.indices.contains(i) == true { edits.captions?.lines.remove(at: i); selectedCaption = nil }
            // A clicked piece of the music is silenced, like the other sound lanes; only the music itself is deleted.
            else if selectedMusic, selectedPart == nil { removeMusic() }
            else if let p = selectedPart { removePart(p) }
        case .split: split()
        case .addMarker: addMarker()
        case .addText: addCallout()
        case .frameBack, .frameForward: step(by: (action == .frameBack ? -1 : 1) / outputFrameRate(rec.fps))
        case .secondBack, .secondForward: step(by: action == .secondBack ? -1 : 1)
        case .previousEdit, .nextEdit: jumpToEdit(forward: action == .nextEdit)
        case .playBackward, .playForward: shuttle(forward: action == .playForward)
        case .stop: pause()
        case .toStart: pause(); seek(edits.trim.start)
        case .toEnd: pause(); seek(edits.trim.end)
        case .newRecording, .stopRecording, .pauseRecording, .prompterHold, .prompterBack, .prompterForward: break // global, handled by ShortcutStore
        }
    }

    /// True when ⌫ (Edit › Delete) has something to delete.
    var hasSelection: Bool {
        selectedZoom != nil || selectedAnnotation != nil || selectedCallout != nil || selectedMarker != nil || selectedCaption != nil || selectedPart != nil || selectedMusic
    }

    // MARK: Copy and paste

    /// A copied zoom, callout, annotation or chapter. Shared by every open editor, so it pastes into another recording.
    enum Copied { case zoom(Zoom), callout(Callout), annotation(Annotation), marker(Marker) }
    static var copied: Copied?

    /// The selected item that Copy, Cut and Duplicate apply to.
    var selectedItem: Copied? {
        if let i = selectedZoom, edits.zooms.indices.contains(i) { return .zoom(edits.zooms[i]) }
        if let i = selectedCallout, edits.callouts.indices.contains(i) { return .callout(edits.callouts[i]) }
        if let i = selectedAnnotation, edits.allAnnotations.indices.contains(i) { return .annotation(edits.allAnnotations[i]) }
        if let i = selectedMarker, edits.allMarkers.indices.contains(i) { return .marker(edits.allMarkers[i]) }
        return nil
    }

    func copy() { if let item = selectedItem { Self.copied = item } }

    func cut() {
        guard selectedItem != nil else { return }
        copy()
        perform(.delete)
    }

    /// Pastes the copied item at the playhead, and selects it.
    func paste() { if let item = Self.copied { insert(item, at: round2(time)) } }

    /// A copy of the selected item, right after it.
    func duplicate() {
        switch selectedItem {
        case .zoom(let z): insert(.zoom(z), at: z.end)
        case .callout(let c): insert(.callout(c), at: c.end)
        case .annotation(let a): insert(.annotation(a), at: a.end)
        case .marker(let m): insert(.marker(m), at: m.t + 1)
        case nil: break
        }
    }

    private func insert(_ item: Copied, at t: Double) {
        switch item {
        // Each paste is an item of its own, so it gets its own id.
        case .zoom(var z):
            (z.start, z.end) = pasteRange(length: z.end - z.start, at: t, duration: duration)
            z.renewID()
            edits.zooms.append(z)
            edits.zooms.sort { $0.start < $1.start }
            selectedZoom = edits.zooms.firstIndex(of: z)
            tab = .cursorZoom
        case .callout(var c):
            (c.start, c.end) = pasteRange(length: c.end - c.start, at: t, duration: duration)
            c.renewID()
            edits.callouts.append(c)
            selectedCallout = edits.callouts.count - 1
        case .annotation(var a):
            (a.start, a.end) = pasteRange(length: a.end - a.start, at: t, duration: duration)
            a.renewID()
            edits.allAnnotations.append(a)
            selectedAnnotation = edits.allAnnotations.count - 1
        case .marker(var m):
            m.t = min(t, duration)
            edits.allMarkers.append(m)
            selectedMarker = edits.allMarkers.firstIndex(of: m)
        }
    }

    /// Splits the clip at the playhead, so either side can be selected and deleted.
    func split() {
        // Splitting changes the item lists, so indices into them are stale.
        if edits.split(at: round2(time)) {
            selectedPart = nil; selectedZoom = nil; selectedAnnotation = nil; selectedCallout = nil
            TipStore.shared.state.seen.insert(.split)
        }
    }

    /// A click at recording time t on a lane: once the clip is split, selects the piece under it. False when there's
    /// nothing to split into pieces, so the click selects the whole item as before.
    @discardableResult
    func selectPart(_ lane: TimelinePart.Lane, at t: Double) -> Bool {
        let segments = edits.keptSegments
        // An unsplit clip is selectable too, for its exact start and end; an unsplit sound isn't.
        guard segments.count > 1 || lane == .clip, let i = segments.firstIndex(where: { t >= $0.start && t <= $0.end }) else { selectedPart = nil; return false }
        (selectedZoom, selectedAnnotation, selectedCallout, selectedMarker, selectedCaption, selectedMusic) = (nil, nil, nil, nil, nil, false)
        selectedPart = TimelinePart(lane: lane, segment: i)
        return true
    }

    /// The clip lane cuts the piece's time from everything; on a sound lane only that sound is silenced there (⌫ again
    /// brings it back, so it stays selected). Zooms, callouts and annotations are split into separate items instead.
    /// The last piece of an inserted clip takes the clip out of the timeline.
    func removePart(_ p: TimelinePart) {
        let segments = edits.keptSegments
        guard segments.indices.contains(p.segment) else { selectedPart = nil; return }
        let r = segments[p.segment]
        switch p.lane {
        case .clip where segments.count == 1: return // the whole recording isn't cut
        case .clip:
            if let i = edits.clipIndex(at: (r.start + r.end) / 2), clipIsOnePiece(i) { removeClip(i); return }
            edits.removeSegment(p.segment)
        case .sound(let s): edits.toggleSilence(s, r); return
        }
        selectedPart = nil
    }

    // MARK: Inserted clips

    /// True while a video is being copied in, to insert or overlay.
    private(set) var insertingClip = false
    /// While an inserted clip is dragged on the timeline: which, and where it would go.
    var clipDrop: (clip: Int, at: Double)?

    /// Copies a video into the recording's folder (converted like an import when it needs to be) and inserts it at
    /// timeline time t, or the playhead: at the nearest split or clip edge within `snap` seconds, else right there.
    func insertClip(from url: URL, at t: Double? = nil, snap: Double = 0) {
        guard !insertingClip else { return }
        let retry = MessageAction(label: "Choose Another…") { [weak self] in self?.chooseClip() }
        guard Importer.extensions.contains(url.pathExtension.lowercased()) else {
            Studio.shared.error = Problem("Couldn’t insert “\(url.lastPathComponent)”", "Only MOV, MP4 and M4V videos can be inserted.", action: retry)
            return
        }
        insertingClip = true
        progress = "Inserting “\(url.deletingPathExtension().lastPathComponent)”…"
        let folder = URL(fileURLWithPath: rec.dir)
        Task { [weak self] in
            do {
                let clip = try await Importer.clip(url, into: folder)
                guard let self else { return }
                pause()
                let at = edits.insertionPoint(near: t ?? time, snap: snap)
                edits.insertClip(clip, at: at)
                (selectedZoom, selectedAnnotation, selectedCallout, selectedMarker, selectedCaption, selectedPart) = (nil, nil, nil, nil, nil, nil)
                seek(at)
            } catch {
                Studio.shared.error = Problem("Couldn’t insert “\(url.lastPathComponent)”", error.localizedDescription, action: retry)
            }
            self?.insertingClip = false
            self?.progress = nil
        }
    }

    /// Copies a video into the recording's folder (converted like an import when it needs to be) and plays it over the
    /// recording from the playhead, for its length or up to the end: centred, a third of the frame wide, its sound off.
    func addVideoOverlay(from url: URL) {
        guard !insertingClip else { return }
        let retry = MessageAction(label: "Choose Another…") { [weak self] in self?.chooseOverlay() }
        guard Importer.extensions.contains(url.pathExtension.lowercased()) else {
            Studio.shared.error = Problem("Couldn’t add “\(url.lastPathComponent)”", "Only MOV, MP4 and M4V videos can play over the recording.", action: retry)
            return
        }
        insertingClip = true
        progress = "Adding “\(url.deletingPathExtension().lastPathComponent)”…"
        let folder = URL(fileURLWithPath: rec.dir)
        Task { [weak self] in
            do {
                let clip = try await Importer.clip(url, into: folder)
                guard let self else { return }
                let start = round2(min(time, max(0, duration - 0.5))), end = round2(min(duration, start + clip.length))
                let w = 1.0 / 3, h = min(0.9, w * Double(size.width) / Double(max(1, size.height)) * Double(clip.height) / Double(max(1, clip.width)))
                var a = Annotation(kind: .video, start: start, end: end, x: 0.5 - w / 2, y: 0.5 - h / 2, w: w, h: h, fade: 0.3)
                a.video = OverlayVideo(path: clip.path, name: clip.name, at: start, length: clip.length, width: clip.width, height: clip.height)
                edits.allAnnotations.append(a)
                selectedAnnotation = edits.allAnnotations.count - 1
            } catch {
                Studio.shared.error = Problem("Couldn’t add “\(url.lastPathComponent)”", error.localizedDescription, action: retry)
            }
            self?.insertingClip = false
            self?.progress = nil
        }
    }

    /// Asks for a video to play over the recording from the playhead.
    func chooseOverlay() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.message = "Choose a video to play over the recording from the playhead. It’s copied into the recording; the original isn’t changed."
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addVideoOverlay(from: url)
    }

    /// Asks for a video and inserts it at the playhead.
    func chooseClip() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.message = "Choose a video to play at the playhead. It’s copied into the recording; the original isn’t changed."
        panel.prompt = "Insert"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        insertClip(from: url, snap: 0.25)
    }

    /// Asks for a picture and places it over the recording at the playhead.
    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a picture to show over the recording from the playhead. It’s copied into the library; the original isn’t changed."
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let image = try Importer.image(url)
            addAnnotation(.image, image: image.path, aspect: image.aspect)
        } catch {
            Studio.shared.error = Problem("Couldn’t add “\(url.lastPathComponent)”", error.localizedDescription,
                                          action: MessageAction(label: "Choose Another…") { [weak self] in self?.chooseImage() })
        }
    }

    /// Moves clip i to the split or clip edge nearest timeline time t, with everything over it.
    func moveClip(_ i: Int, to t: Double) {
        edits.moveClip(i, to: t)
        selectedPart = nil
    }

    /// True when inserted clip i isn't split, so its one piece is the whole clip. Only then can it be deleted from a
    /// selected piece: a piece never takes the rest of the clip with it.
    func clipIsOnePiece(_ i: Int) -> Bool {
        guard edits.allClips.indices.contains(i) else { return false }
        let c = edits.allClips[i]
        return edits.keptSegments.filter { $0.end > c.at + 1e-6 && $0.start < c.end - 1e-6 }.count == 1
    }

    /// Takes clip i out of the timeline; its file stays in the folder until the recording is deleted, so undo works.
    func removeClip(_ i: Int) {
        edits.removeClip(i)
        selectedPart = nil
    }

    func setClipVolume(_ i: Int, _ v: Double) {
        var all = edits.allClips
        guard all.indices.contains(i) else { return }
        all[i].volume = v >= 1 ? nil : max(0, v)
        edits.allClips = all
    }

    func setTrimStart() { if time < edits.trim.end - 0.5 { edits.trim.start = round2(time) } }
    func setTrimEnd() { if time > edits.trim.start + 0.5 { edits.trim.end = round2(time) } }

    // MARK: Export

    /// Opens the Export sheet, named after the title unless a name was typed in this window.
    func openExport() {
        if exportName.trimmingCharacters(in: .whitespaces).isEmpty { exportName = exportTitle }
        showExport = true
    }

    private var exportTitle: String { title.trimmingCharacters(in: .whitespaces).isEmpty ? rec.title : title }

    /// Where the export goes with the chosen name, folder, format and extras: the video, or a folder holding it and its extras.
    var exportURL: URL { exportPlace(named: exportName) }

    func exportPlace(named name: String) -> URL {
        let o = exportSettings
        return ExportJob.place(outDir: URL(fileURLWithPath: o.folder), name: name, format: o.format, extras: o.extras.intersection(o.availableExtras(for: edits)))
    }

    func runExport() {
        if case .working = export { return }
        pause()
        export = .working("Rendering", 0)
        let o = exportSettings
        let job = ExportJob(rec, edits: edits, cursor: cursor, title: exportTitle, name: exportName, settings: o)
        let id = rec.id, preset = o.format.rawValue
        exportTask = Task {
            do {
                let res = try await Exporter.run(job, transcribe: { try await Transcriber.transcribe($0) }) { stage, p in
                    Task { @MainActor [weak self] in if case .working = self?.export { self?.export = .working(stage, p) } }
                }
                try Studio.shared.library?.addExport(id: id, path: res.video, preset: preset)
                export = .done(video: res.video, place: res.place, transcriptError: res.transcriptError)
                TipStore.shared.done(.export)
                await Studio.shared.load()
            } catch is CancellationError {
                export = .idle
            } catch {
                export = .failed(error.localizedDescription)
            }
        }
    }

    /// The extra files that can be saved with the chosen format and edits.
    var availableExtras: ExportExtras { exportSettings.availableExtras(for: edits) }

    /// Stops the export under way; the unfinished file is removed.
    func cancelExport() {
        exportTask?.cancel()
        export = .idle
    }

    /// Why the chosen format can't be exported, if it can't.
    var formatBlocker: String? {
        switch exportSettings.format {
        case .webm where !Tools.hasFFmpeg: return "Needs ffmpeg: brew install ffmpeg"
        case .gif where outputDuration(edits.timeMap) > GIFOptions.maxSeconds + 0.01:
            return "This clip is longer than \(Int(GIFOptions.maxSeconds)) seconds. Trim it, or export a video."
        default: return nil
        }
    }

    /// The export's poster frame, a second in as `Exporter` takes it, drawn by the same renderer from the full edits,
    /// for the Export sheet. Nil until the player has its sources.
    func exportPoster(maxSize: Double) async -> CGImage? {
        guard let sources else { return nil }
        let edits = edits, cursor = cursor, rec = rec, cursorImages = cursorImages, keys = keys
        let renderer = await Task.detached {
            FrameRenderer(edits: edits, cursor: cursor, sourceWidth: rec.width, sourceHeight: rec.height, duration: rec.duration,
                          windowCornerPx: rec.windowCornerPx, cursorImages: cursorImages, keys: keys)
        }.value
        guard let comp = try? await Composition.make(sources, renderer: renderer, fps: rec.fps) else { return nil }
        let gen = AVAssetImageGenerator(asset: sources.asset)
        gen.videoComposition = comp
        gen.maximumSize = CGSize(width: maxSize, height: maxSize)
        let at = min(1, outputDuration(edits.timeMap) / 3)
        return try? await gen.image(at: CMTime(seconds: at, preferredTimescale: 600)).image
    }

    /// The exported video's frame at a resolution preset (smaller when the recording is).
    func exportSize(_ r: ExportResolution) -> OutputSize { outputSize(width: rec.width, height: rec.height, edits, maxLongSide: r.longSide) }

    /// "0:56 · about 38 MB", for the Export sheet.
    var exportEstimate: String {
        let o = exportSettings, len = outputDuration(edits.timeMap)
        let bytes: Int
        if o.format == .gif {
            bytes = gifEstimatedBytes(size, seconds: len, o.gif)
        } else {
            let s = exportSize(o.resolution)
            bytes = videoEstimatedBytes(width: s.width, height: s.height, fps: outputFrameRate(rec.fps), seconds: len, o.quality, hevc: o.format != .mp4)
        }
        return "\(formatTime(len)) · about \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
    }

    /// Closes the Export sheet and shows where to fix a problem from `validateEdits`, selecting the item it names.
    func reveal(_ problem: String) {
        let head = problem.prefix { $0 != ":" }
        let index = head.split(separator: " ").last.flatMap { Int($0) }.map { $0 - 1 }
        // Callouts, annotations and chapters open as the selection; trim, clips and speeds are on the timeline only, so
        // they keep the tab.
        let tabs: [(String, InspectorTab)] = [("Zoom", .cursorZoom), ("Caption", .overlays), ("Every caption", .overlays),
                                              ("Webcam", .overlays), ("Shortcut", .overlays), ("Crop", .look),
                                              ("Audio", .sound), ("Microphone", .sound), ("System audio", .sound),
                                              ("Padding", .look), ("Corner", .look), ("Shadow", .look),
                                              ("Gradient", .look), ("Background", .look), ("Aspect", .look)]
        if let t = tabs.first(where: { problem.hasPrefix($0.0) })?.1 { tab = t }
        showInspector = true
        showExport = false
        if let index {
            if head.hasPrefix("Zoom") { selectedZoom = index }
            else if head.hasPrefix("Callout") { selectedCallout = index }
            else if head.hasPrefix("Annotation") { selectAnnotation(index) }
            else if head.hasPrefix("Chapter") { (selectedMarker, renamingMarker) = (index, index) }
        }
    }
}

func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

func timecode(_ s: Double) -> String { "\(formatTime(s)).\(Int((max(0, s).truncatingRemainder(dividingBy: 1)) * 10))" }
