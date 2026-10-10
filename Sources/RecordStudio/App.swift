import AppKit
import RecordCore
import RecordKit
import SwiftUI

@main
struct RecordStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var studio = Studio.shared

    var body: some Scene {
        Window("RecordStudio", id: "main") {
            RootView()
                .environment(studio)
                .tint(.graphite)
                .frame(minWidth: 700, minHeight: 600) // half of a 13" screen is 720 pt, for tiling beside another app
                .background(WindowGrabber { studio.mainWindow = $0 })
        }
        .defaultSize(width: 1240, height: 820)
        .windowToolbarStyle(.unified)
        .commands { AppCommands(studio: studio) }

        Settings { SettingsView().tint(.graphite) }

        Window("Keyboard Shortcuts", id: ShortcutsOverlay.id) { ShortcutsOverlay().tint(.graphite) }
            .windowResizability(.contentSize)
            .restorationBehavior(.disabled)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppAppearance.apply()
        StatusItem.shared.install()
        ShortcutStore.shared.registerGlobal()
        Updater.shared.start()
        Task { @MainActor in await Studio.shared.load() }
        PermissionCenter.shared.showWelcomeIfNew()
    }

    /// Project files double-clicked in Finder or dropped on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls where url.pathExtension.lowercased() == Project.fileExtension { await Studio.shared.openProject(url) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        Task { @MainActor in Studio.shared.showMain() }
        return true
    }

    /// Quitting mid-recording keeps what was captured.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Studio.shared.isRecording else { return .terminateNow }
        Task { @MainActor in
            await Studio.shared.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct RootView: View {
    @Environment(Studio.self) private var studio

    var body: some View {
        @Bindable var studio = studio
        NavigationStack(path: $studio.path) {
            LibraryView()
                .navigationDestination(for: String.self) { id in
                    if let rec = studio.recording(id) {
                        EditorView(rec: rec).id(rec.id)
                    } else {
                        ContentUnavailableView("This recording no longer exists", systemImage: "film.stack")
                    }
                }
        }
        // Fades out onto the editor's stage, which opens on the same canvas, so finishing and opening read as one step.
        .overlay { if let length = studio.finishing { FinishingView(length: length).transition(.opacity) } }
        .motion(Motion.exit, value: studio.finishing == nil)
        .alert(studio.error?.title ?? "", isPresented: Binding(get: { studio.error != nil }, set: { if !$0 { studio.error = nil } }),
               presenting: studio.error) { problem in
            if let action = problem.action { Button(action.label, action: action.run) }
            Button(problem.action == nil ? "OK" : "Cancel", role: .cancel) {}
        } message: { problem in
            Text(problem.message)
        }
    }
}

/// Covers the window between Stop and the editor opening, which can take a while after a long or paused recording.
private struct FinishingView: View {
    let length: TimeInterval

    var body: some View {
        VStack(spacing: Space.s) {
            ProgressView().controlSize(.small)
            Text("Finishing your recording…").font(.headline)
            Text("\(formatTime(length)) recorded. It opens in the editor once it's ready.").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor)) // the editor's stage, which comes next
    }
}

/// Hands the hosting NSWindow to the model so the recording flow can hide and restore it.
struct WindowGrabber: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
