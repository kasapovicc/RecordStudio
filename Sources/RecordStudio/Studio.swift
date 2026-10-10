import AppKit
import Observation
import RecordCore
import RecordKit
import UniformTypeIdentifiers

// One pattern for each kind of message, used everywhere:
// - something is happening: a progress capsule (`ProgressCapsule`), at the bottom of what it's happening in;
// - something finished, or is worth knowing: a `Toast` at the bottom of the editor that goes away by itself;
// - something failed: a `Problem`, an alert whose title says what failed and whose message says why, with a button
//   that fixes it when there is one;
// - something blocks an action: the Export sheet lists what blocks exporting, each with Show (see `EditorModel.problems`).

/// A button a message offers, such as "Show in Finder" or "Choose Another…".
struct MessageAction {
    let label: String
    let run: () -> Void
}

/// Something that failed. The title names what failed ("Couldn’t insert “Demo.mov”"), never a generic one.
struct Problem {
    var title: String
    var message: String
    var action: MessageAction?
    init(_ title: String, _ message: String, action: MessageAction? = nil) { (self.title, self.message, self.action) = (title, message, action) }
}

/// Something finished, or worth knowing, with at most one thing to do about it.
struct Toast {
    var text: String
    var action: MessageAction?
}

/// App-wide state: the library, the active recording, and the floating panels around it.
@MainActor @Observable
final class Studio {
    static let shared = Studio()

    var recordings: [Recording] = []
    var path: [String] = [] // navigation: ids of open recordings
    var error: Problem?
    private(set) var recorder: Recorder?
    private(set) var recordingStarted: Date?
    /// The length of the recording being finished after Stop (parts joined, saved), while that's under way.
    private(set) var finishing: TimeInterval?
    let library: Library?
    let camera = CameraRig()
    @ObservationIgnored weak var mainWindow: NSWindow?
    /// The open editor, for the Edit menu's Undo and Redo.
    weak var editor: EditorModel?
    /// The saved looks, shared by every editor; saved as they change.
    var looks = Looks.load() {
        didSet {
            do { try looks.save() } catch { self.error = Problem("Couldn’t save the looks", error.localizedDescription) }
        }
    }

    var isRecording: Bool { recorder != nil }
    /// The recording is paused: nothing is being written.
    private(set) var isPaused = false { didSet { Teleprompter.shared.recordingPaused(isPaused) } }
    /// A pause or resume is under way; the controls wait for it.
    var isPausing: Bool { pausing != nil }
    private var pausing: Task<Void, Never>?
    /// The record bar's "System audio" switch, read when a recording starts.
    static let systemAudioKey = "systemAudio"
    static let keystrokesKey = "keystrokes"
    static let hideDesktopIconsKey = CaptureExclusion.defaultsKey
    /// Seconds of 3-2-1 before a recording starts: 0 (off), 3 or 5.
    static let countdownKey = "countdown"

    private init() {
        do { library = try Library() } catch {
            library = nil
            self.error = Problem("Couldn’t open the library", "\(error.localizedDescription) It’s kept at \(Paths.data.path).")
        }
        // Files deleted in Finder, or a library drive plugged back in, show up when the app comes back to the front.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await Studio.shared.load() }
        }
    }

    func load() async {
        guard let library else { return }
        await library.recoverOrphans()
        do { recordings = try library.list() } catch { self.error = Problem("Couldn’t list the recordings", error.localizedDescription) }
    }

    func recording(_ id: String) -> Recording? { recordings.first { $0.id == id } }

    // MARK: Recording flow: bar -> (picker) -> recording + HUD -> editor

    func newRecording() {
        guard !isRecording, finishing == nil, !Panels.shared.isCountingDown else { return }
        mainWindow?.orderOut(nil)
        Panels.shared.showBar()
        Teleprompter.shared.begin()
    }

    func cancelNewRecording() {
        Panels.shared.closeBar()
        Teleprompter.shared.end()
        cameraOff()
        showMain()
    }

    /// Picks the webcam for the next recording (nil = none) and shows or hides its live preview bubble.
    func useCamera(_ id: String?) async {
        do {
            try await camera.use(id)
            if id == nil { Panels.shared.closeCameraPreview() } else { Panels.shared.showCameraPreview(session: camera.session) }
        } catch {
            Panels.shared.closeCameraPreview()
            self.error = Problem("Couldn’t turn on the camera", error.localizedDescription)
        }
    }

    private func cameraOff() {
        Panels.shared.closeCameraPreview()
        Task { try? await camera.use(nil) }
    }

    /// What the current recording captures, to record it again on Restart.
    @ObservationIgnored private var take: (source: CaptureSource, microphone: String?)?

    func start(_ source: CaptureSource, microphone: String?) async {
        Panels.shared.closeBar()
        Panels.shared.showRecordedDim(source)
        // Esc during the countdown brings the bar back, so the recording can be set up again.
        guard await Panels.shared.countdown(UserDefaults.standard.object(forKey: Self.countdownKey) as? Int ?? 3, on: source) else {
            Panels.shared.closeRecordedDim()
            Panels.shared.restoreWindow()
            Panels.shared.showBar()
            return
        }
        let rec = Recorder()
        rec.onError = { [weak self] error in Task { @MainActor in self?.failed(error) } }
        do {
            try await rec.start(source, microphone: microphone, systemAudio: UserDefaults.standard.bool(forKey: Self.systemAudioKey),
                                camera: camera.isActive ? camera : nil, keystrokes: UserDefaults.standard.object(forKey: Self.keystrokesKey) as? Bool ?? true,
                                hideDesktopIcons: CaptureExclusion.hidesDesktopIcons(), clickThrough: Panels.shared.dimWindows)
        } catch {
            failed(error)
            return
        }
        recorder = rec
        recordingStarted = Date()
        Teleprompter.shared.recordingStarted()
        if Teleprompter.shared.isShowing { try? SpeakerNotes.keep(Teleprompter.shared.notes, in: rec.dir) }
        take = (source, microphone)
        Panels.shared.showHUD(on: source, microphone: microphone)
        StatusItem.shared.update()
    }

    /// Throws the current take away (to the Trash, not into the library) and records the same thing again after the
    /// countdown.
    func restart() async {
        guard let rec = recorder, let take else { return }
        recorder = nil
        recordingStarted = nil
        await pausing?.value
        isPaused = false
        Panels.shared.closeHUD()
        StatusItem.shared.update()
        _ = try? await rec.stop()
        try? FileManager.default.trashItem(at: rec.dir, resultingItemURL: nil)
        Teleprompter.shared.begin() // the notes start again from the top
        await start(take.source, microphone: take.microphone)
    }

    /// Pauses the recording, or carries on with it. If it can't carry on (the window it records has closed), the
    /// recording ends there, keeping what was captured.
    func togglePause() {
        guard let rec = recorder, pausing == nil else { return }
        let resuming = rec.isPaused
        if !resuming { isPaused = true } // shown at once; resuming shows once recording has really started again
        pausing = Task {
            do {
                if resuming { try await rec.resume() } else { try await rec.pause() }
            } catch {
                failed(error)
            }
            if recorder === rec { isPaused = rec.isPaused }
            pausing = nil
            StatusItem.shared.update()
        }
        StatusItem.shared.update()
    }

    func stop() async {
        guard let rec = recorder else { return }
        recorder = nil
        recordingStarted = nil
        await pausing?.value // a part still being closed or opened is finished first
        isPaused = false
        Panels.shared.closeHUD()
        Teleprompter.shared.end()
        StatusItem.shared.update()
        // The window says what's happening at once, rather than staying hidden until the recording is ready.
        finishing = rec.elapsed
        showMain()
        defer { cameraOff(); finishing = nil }
        let stopped: Result<URL, Error>
        do { stopped = .success(try await rec.stop()) } catch { stopped = .failure(error) }
        // Put a resized window back only once capture has stopped, so no frame catches it at its old size.
        Panels.shared.restoreWindow()
        do {
            let dir = try stopped.get()
            let title = "Recording \(Date().formatted(.dateTime.day().month(.abbreviated).hour().minute()))"
            guard let library else { throw StudioError.message("The library isn't available.") }
            let saved = try await library.insert(id: rec.id, title: title, dir: dir)
            await load()
            path = [saved.id]
        } catch {
            self.error = Problem("Couldn’t save the recording", error.localizedDescription)
            await load()
        }
        showMain()
    }

    private func failed(_ error: Error) {
        if recorder != nil {
            Task { await stop() } // keep whatever was captured
        } else {
            Panels.shared.closeBar()
            Panels.shared.closeHUD()
            Panels.shared.restoreWindow()
            Teleprompter.shared.end()
            cameraOff()
        }
        self.error = Problem("Couldn’t record", error.localizedDescription)
        showMain()
    }

    func showMain() {
        NSApp.activate()
        if let w = mainWindow { w.makeKeyAndOrderFront(nil) }
    }

    // MARK: Library actions

    /// The recordings last moved to the Trash together and where each went, for the Edit menu's Undo in the library.
    /// ponytail: only the last delete; a stack if people ask to undo several.
    private(set) var trashed: [(rec: Recording, items: [URL: URL])] = []

    func delete(_ recs: [Recording]) {
        guard let library else { return }
        trashed = []
        for rec in recs {
            do {
                trashed.append((rec, try library.delete(id: rec.id)))
                path.removeAll { $0 == rec.id }
            } catch { self.error = Problem("Couldn’t move “\(rec.title)” to the Trash", error.localizedDescription) }
        }
        Task { await load() }
    }

    func undoDelete() {
        let batch = trashed
        trashed = []
        for (rec, items) in batch {
            do { try library?.restore(rec, from: items) } catch { self.error = Problem("Couldn’t put back “\(rec.title)”", error.localizedDescription) }
        }
        Task { await load() }
    }

    /// The recordings selected in the library, for File › Export.
    var librarySelection: Set<String> = []
    /// "Exporting 2 of 5…" while the library exports several recordings; nil otherwise.
    private(set) var exporting: String?
    /// Something finished in the library, such as an export.
    var libraryToast: Toast?
    @ObservationIgnored private var exportTask: Task<Void, Never>?

    /// Exports each recording with its own saved export settings, one after another, named after its title. A file
    /// that's already there is replaced only when it's that recording's own export; otherwise both are kept.
    func export(_ recs: [Recording]) {
        let recs = recs.filter { !$0.isMissing }
        guard exportTask == nil, !recs.isEmpty else { return }
        exportTask = Task {
            var videos: [String] = [], places: [String] = [], failures: [(title: String, why: String)] = []
            for (i, rec) in recs.enumerated() where !Task.isCancelled {
                exporting = "Exporting \(i + 1) of \(recs.count)…"
                do {
                    let o = ExportSettings.load(for: rec.id), cursor = rec.cursorSamples
                    var job = ExportJob(rec, edits: try rec.openingEdits(cursor: cursor), cursor: cursor, title: rec.title, name: rec.title, settings: o)
                    job.name = rec.exportName(folder: o.folder, format: o.format, extras: job.extras, taken: videos)
                    let res = try await Exporter.run(job, transcribe: { try await Transcriber.transcribe($0) }) { _, _ in }
                    try library?.addExport(id: rec.id, path: res.video, preset: o.format.rawValue)
                    videos.append(res.video)
                    places.append(res.place)
                    if let t = res.transcriptError { failures.append((rec.title, "Exported, but the transcript couldn’t be made: \(t)")) }
                } catch {
                    if !Task.isCancelled { failures.append((rec.title, error.localizedDescription)) }
                }
            }
            exporting = nil
            exportTask = nil
            await load()
            if !videos.isEmpty {
                libraryToast = Toast(text: videos.count == 1 ? "Exported 1 recording." : "Exported \(videos.count) recordings.",
                                     action: MessageAction(label: "Show in Finder") { Studio.shared.reveal(all: places) })
            }
            if !failures.isEmpty {
                error = Problem(failures.count == 1 ? "Couldn’t export “\(failures[0].title)”" : "Couldn’t export \(failures.count) recordings",
                                failures.map { "“\($0.title)”: \($0.why)" }.joined(separator: "\n"))
            }
        }
    }

    /// Stops the library's export after the recording under way, whose unfinished file is removed.
    func cancelExport() { exportTask?.cancel() }

    /// Renames a recording from the library, and its project file when it has one.
    func rename(_ rec: Recording, to title: String) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != rec.title, let library else { return }
        do {
            try library.rename(id: rec.id, title: name)
            Task { await load() }
        } catch { self.error = Problem("Couldn’t rename “\(rec.title)”", error.localizedDescription); return }
        let root = library.root
        guard FileManager.default.fileExists(atPath: Project.autosaveURL(id: rec.id, title: rec.title, root: root).path),
              let json = rec.edits, let edits = try? JSONDecoder().decode(Edits.self, from: Data(json.utf8)) else { return }
        Task { try? await Project.autosave(rec, title: name, edits: edits, root: root) }
    }

    // MARK: Project files

    static let projectType = UTType(filenameExtension: Project.fileExtension) ?? .data

    /// Imports a project file as a new recording and opens it in the editor.
    /// The video being imported, while one is; the library shows it.
    private(set) var importing: String?

    /// Copies videos made elsewhere into the library as recordings, one after another, and opens the last in the
    /// editor. Each is named after its file and dated when it was shot, where the file says.
    func importVideos(_ urls: [URL]) async {
        guard let library else { return }
        let videos = urls.filter { Importer.extensions.contains($0.pathExtension.lowercased()) }
        var opened: String?
        for url in videos {
            importing = url.deletingPathExtension().lastPathComponent
            // The folder is named by the time of the import (unique), like a recording's; the date shown is the video's own.
            let id = String(max(Int64(Date().timeIntervalSince1970 * 1000), (recordings.compactMap { Int64($0.id) }.max() ?? 0) + 1))
            let dir = library.root.appending(path: "recordings/\(id)")
            do {
                let shot = try await Importer.importVideo(url, into: dir)
                let rec = try await library.insert(id: id, title: url.deletingPathExtension().lastPathComponent, dir: dir,
                                                   createdAt: shot.map { Int64($0.timeIntervalSince1970 * 1000) })
                recordings.removeAll { $0.id == rec.id }
                recordings.insert(rec, at: 0)
                opened = rec.id
            } catch {
                try? FileManager.default.removeItem(at: dir)
                self.error = Problem("Couldn’t import “\(url.lastPathComponent)”", error.localizedDescription,
                                     action: MessageAction(label: "Choose Another…") { Studio.shared.chooseVideos() })
            }
        }
        importing = nil
        if let opened { showMain(); path = [opened] }
    }

    func chooseVideos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = true
        panel.message = "Choose videos to edit. They’re copied into the library; the originals aren’t changed."
        guard panel.runModal() == .OK else { return }
        Task { await importVideos(panel.urls) }
    }

    func openProject(_ url: URL) async {
        guard let library else { return }
        do {
            let rec = try await Project.open(url, into: library)
            recordings.removeAll { $0.id == rec.id }
            recordings.insert(rec, at: 0)
            showMain()
            path = [rec.id]
        } catch {
            self.error = Problem("Couldn’t open “\(url.lastPathComponent)”", error.localizedDescription)
        }
    }

    /// Opens a fresh copy of the sample project that ships with the app, so the editor can be tried without recording first.
    func openSample() {
        guard let url = Bundle.main.url(forResource: "Sample", withExtension: Project.fileExtension) else {
            error = Problem("Couldn’t open the sample project", "It isn’t in this copy of RecordStudio.")
            return
        }
        Task { await openProject(url) }
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.projectType]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        Task { for url in panel.urls { await openProject(url) } }
    }

    /// Saves the open recording and its edits as one file to send to someone else.
    func saveProject() {
        guard let editor else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.projectType]
        panel.nameFieldStringValue = safeFilename(editor.title.isEmpty ? editor.rec.title : editor.title) + "." + Project.fileExtension
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rec = editor.rec, title = editor.title, edits = editor.edits
        editor.progress = "Saving the project…"
        Task {
            do {
                try await Project.save(rec, title: title, edits: edits, to: url)
                editor.toast = Toast(text: "Saved “\(url.lastPathComponent)”. Anyone with RecordStudio can open it.",
                                     action: MessageAction(label: "Show in Finder") { Studio.shared.reveal(url.path) })
            } catch {
                self.error = Problem("Couldn’t save the project", error.localizedDescription)
            }
            editor.progress = nil
        }
    }

    /// Shows the recording's own project file, which is kept up to date as it's edited.
    func revealProject(_ rec: Recording) {
        guard let root = library?.root else { return }
        let url = Project.autosaveURL(id: rec.id, title: rec.title, root: root)
        if FileManager.default.fileExists(atPath: url.path) { reveal(url.path) }
        else { error = Problem("“\(rec.title)” has no project file yet", "It’s written a few seconds after the recording is opened or edited.") }
    }

    func reveal(_ paths: String...) { reveal(all: paths) }
    func reveal(all paths: [String]) { NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) }) }

    func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}
