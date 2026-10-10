import AppKit
import RecordCore
import RecordKit
import SwiftUI

/// The menu bar: every command from the toolbars and right-click menus, with its shortcut. Editor shortcuts come from
/// the user's own map, so the menus show what's set in Settings. Single keys (Space, S, I…) are still handled by
/// `EditorKeys` first; the menu only shows them and runs the command when it's picked.
struct AppCommands: Commands {
    let studio: Studio
    @Environment(\.openWindow) private var openWindow

    private var editor: EditorModel? { studio.editor }
    private var keys: ShortcutMap { ShortcutStore.shared.map }
    private var librarySelection: [Recording] { studio.recordings.filter { studio.librarySelection.contains($0.id) } }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Updater.shared.check(userInitiated: true) }
        }

        CommandGroup(replacing: .newItem) {
            Button("New Recording…") { studio.newRecording() }
                .keyboardShortcut("n")
                .disabled(studio.isRecording || studio.finishing != nil)
            Button("Open Project…") { studio.chooseProject() }
                .keyboardShortcut("o")
            Button("Import Video…") { studio.chooseVideos() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(studio.importing != nil)
        }
        // Replacing .saveItem also drops the system Close, so it's put back here. performClose goes the same way as
        // the red button, so each window's own close handling (an export running, unsaved state) still applies.
        CommandGroup(replacing: .saveItem) {
            Button("Close") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w")
            Divider()
            Button("Show Project in Finder") { if let e = editor { studio.revealProject(studio.recording(e.rec.id) ?? e.rec) } }
                .disabled(editor == nil)
            Button("Save Project As…") { studio.saveProject() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(editor == nil)
            Divider()
            // In the library, exports the selected recordings with their own settings.
            if editor == nil, !librarySelection.isEmpty {
                Button(librarySelection.count == 1 ? "Export" : "Export \(librarySelection.count) Recordings") { studio.export(librarySelection) }
                    .keyboardShortcut("e")
                    .disabled(studio.exporting != nil)
            } else {
                Button("Export…") { editor?.openExport() }
                    .keyboardShortcut("e")
                    .disabled(editor == nil)
            }
        }

        // ponytail: replaces the system Undo, so text fields in the editor undo through the edit history too.
        CommandGroup(replacing: .undoRedo) {
            // In the library, Undo brings back the recordings last moved to the Trash.
            if editor == nil, !studio.trashed.isEmpty {
                Button("Undo Move to Trash") { studio.undoDelete() }
                    .keyboardShortcut("z")
            } else {
                Button("Undo") { editor?.undo() }
                    .keyboardShortcut("z")
                    .disabled(editor?.history.canUndo != true)
            }
            Button("Redo") { editor?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(editor?.history.canRedo != true)
        }
        // Text being typed keeps the usual Cut, Copy and Paste; otherwise they apply to the selected timeline item.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { if !toText(#selector(NSText.cut(_:))) { editor?.cut() } }
                .keyboardShortcut("x")
            Button("Copy") { if !toText(#selector(NSText.copy(_:))) { editor?.copy() } }
                .keyboardShortcut("c")
            Button("Paste") { if !toText(#selector(NSText.paste(_:))) { editor?.paste() } }
                .keyboardShortcut("v")
            Button("Duplicate") { editor?.duplicate() }
                .keyboardShortcut("d")
                .disabled(editor?.selectedItem == nil)
            Button("Delete") { if !toText(#selector(NSResponder.deleteBackward(_:))) { editor?.perform(.delete) } }
                .keyboardShortcut(keys[.delete]?.keyboardShortcut)
                .disabled(editor?.hasSelection != true)
            Button("Select All") { _ = toText(#selector(NSText.selectAll(_:))) }
                .keyboardShortcut("a")
        }

        CommandMenu("Clip") {
            Group {
                Button(editor?.playing == true ? "Pause" : "Play") { editor?.togglePlay() }
                    .keyboardShortcut(keys[.play]?.keyboardShortcut)
                Divider()
                Button("Split at Playhead") { editor?.split() }
                    .keyboardShortcut(keys[.split]?.keyboardShortcut)
                Button("Set Trim Start") { editor?.setTrimStart() }
                    .keyboardShortcut(keys[.setIn]?.keyboardShortcut)
                Button("Set Trim End") { editor?.setTrimEnd() }
                    .keyboardShortcut(keys[.setOut]?.keyboardShortcut)
                Menu("Speed") {
                    ForEach(Self.speeds, id: \.self) { v in
                        Button(v == 1 ? "Normal (1×)" : speedLabel(v)) { editor?.setSpeed(v) }
                    }
                }
                Button("Remove Pauses…") { editor?.showPauses = true }
                    .disabled(editor?.rec.hasAudio != true)
                Button("Crop…") { editor?.cropping = true }
                    .disabled(editor?.cropping == true)
                Divider()
                Button("Insert Clip…") { editor?.chooseClip() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(editor?.insertingClip == true)
            }
            .disabled(editor == nil)
        }

        CommandMenu("Insert") {
            Group {
                Button("Zoom") { editor?.addZoom() }
                    .keyboardShortcut(keys[.addZoom]?.keyboardShortcut)
                Button("Chapter") { editor?.addMarker() }
                    .keyboardShortcut(keys[.addMarker]?.keyboardShortcut)
                Button("Text") { editor?.addCallout() }
                    .keyboardShortcut(keys[.addText]?.keyboardShortcut)
                Divider()
                ForEach([Annotation.Kind.arrow, .rectangle, .ellipse], id: \.self) { k in
                    Button(k.name) { editor?.addAnnotation(k) }
                }
                Button("Image…") { editor?.chooseImage() }
                Button("Video Overlay…") { editor?.chooseOverlay() }
                    .disabled(editor?.insertingClip == true)
                Divider()
                Button("Blur") { editor?.addAnnotation(.blur) }
                Button("Pixelate") { editor?.addAnnotation(.blur, pixelate: true) }
            }
            .disabled(editor == nil)
        }

        CommandGroup(before: .toolbar) {
            Button(editor?.showInspector == false ? "Show Inspector" : "Hide Inspector") { editor?.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(editor == nil)
            ForEach(Array(InspectorTab.allCases.enumerated()), id: \.element) { n, tab in
                // Stays ⌘3 even when this recording has no overlays to show.
                Button(tab.name) { editor?.deselect(); editor?.tab = tab; editor?.showInspector = true }
                    .keyboardShortcut(KeyEquivalent(Character("\(n + 1)")))
                    .disabled(editor?.tabs.contains(tab) != true)
            }
            Divider()
            Group {
                Button("Zoom Timeline In") { editor?.zoomTimeline(by: 1.5) }
                    .keyboardShortcut("=")
                    .disabled(editor.map { $0.timelineZoom >= $0.maxTimelineZoom } ?? true)
                Button("Zoom Timeline Out") { editor?.zoomTimeline(by: 1 / 1.5) }
                    .keyboardShortcut("-")
                    .disabled(editor.map { $0.timelineZoom <= 1 } ?? true)
                Button("Fit Timeline to Window") { editor?.timelineZoom = 1 }
                    .keyboardShortcut("0")
                    .disabled(editor.map { $0.timelineZoom <= 1 } ?? true)
            }
            Divider()
        }

        CommandMenu("Record") {
            Button("New Recording…") { studio.newRecording() }
                .keyboardShortcut(keys[.newRecording]?.keyboardShortcut)
                .disabled(studio.isRecording || studio.finishing != nil)
            Button(studio.isPaused ? "Resume Recording" : "Pause Recording") { studio.togglePause() }
                .keyboardShortcut(keys[.pauseRecording]?.keyboardShortcut)
                .disabled(!studio.isRecording || studio.isPausing)
            Button("Stop Recording") { Task { await studio.stop() } }
                .keyboardShortcut(".")
                .disabled(!studio.isRecording)
        }

        CommandGroup(replacing: .help) {
            Button("Welcome to RecordStudio") { PermissionCenter.shared.showWelcome() }
            Button("Open Sample Project") { Studio.shared.openSample() }
            Button("RecordStudio Help") { NSWorkspace.shared.open(URL(string: "https://github.com/\(Updater.repository)#getting-started")!) }
            Button("Keyboard Shortcuts") { openWindow(id: ShortcutsOverlay.id) }
                .keyboardShortcut("/")
            Button("Reset Tips") { TipStore.shared.state.reset() }
        }
    }

    private static let speeds: [Double] = [0.5, 1] + SpeedRegion.speeds.filter { $0 > 1 }

    /// Sends a text command to the text being typed in, if any. False when nothing is being typed.
    private func toText(_ action: Selector) -> Bool {
        guard NSApp.keyWindow?.firstResponder is NSText else { return false }
        return NSApp.sendAction(action, to: nil, from: nil)
    }
}

extension Shortcut {
    /// The same keys as a menu shortcut.
    var keyboardShortcut: KeyboardShortcut? {
        let named: [String: KeyEquivalent] = ["space": .space, "delete": .delete, "return": .return, "tab": .tab, "escape": .escape,
                                              "left": .leftArrow, "right": .rightArrow, "up": .upArrow, "down": .downArrow]
        let equivalent: KeyEquivalent
        if let k = named[key] { equivalent = k }
        else if key.hasPrefix("f"), let n = Int(key.dropFirst()), let f = UnicodeScalar(NSF1FunctionKey + n - 1) { equivalent = KeyEquivalent(Character(f)) }
        else if key.count == 1, let c = key.first { equivalent = KeyEquivalent(c) }
        else { return nil }
        var mods: EventModifiers = []
        if modifiers.contains(.command) { mods.insert(.command) }
        if modifiers.contains(.option) { mods.insert(.option) }
        if modifiers.contains(.control) { mods.insert(.control) }
        if modifiers.contains(.shift) { mods.insert(.shift) }
        return KeyboardShortcut(equivalent, modifiers: mods)
    }
}
