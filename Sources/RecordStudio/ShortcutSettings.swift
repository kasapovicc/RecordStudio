import AppKit
import Carbon.HIToolbox
import Observation
import RecordCore
import RecordKit
import SwiftUI

/// The user's shortcuts, kept in UserDefaults. Owns the global hotkeys (Carbon's RegisterEventHotKey,
/// which needs no Accessibility permission) and the key recorder in Settings.
@MainActor @Observable
final class ShortcutStore {
    static let shared = ShortcutStore()
    private static let defaultsKey = "shortcuts"

    var map: ShortcutMap {
        didSet {
            UserDefaults.standard.set(map.stored, forKey: Self.defaultsKey)
            registerGlobal()
        }
    }
    /// Global actions whose shortcut another app has already claimed.
    private(set) var unavailable: Set<ShortcutAction> = []
    /// The action whose new shortcut is being typed, and why the last attempt was refused.
    private(set) var recording: ShortcutAction?
    private(set) var problem: String?

    @ObservationIgnored private var hotkeys: [EventHotKeyRef] = []
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private var monitor: Any?

    private init() {
        map = ShortcutMap(stored: UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:])
    }

    // MARK: Global hotkeys

    func registerGlobal() {
        installHandler()
        for ref in hotkeys { UnregisterEventHotKey(ref) }
        hotkeys = []
        var failed: Set<ShortcutAction> = []
        // Paused while a shortcut is being recorded, so typing the current one reaches the recorder.
        if recording == nil {
            for (i, action) in ShortcutAction.allCases.enumerated() where action.isGlobal {
                guard let s = map[action], s.isSafeGlobally, let code = Self.keyCode(s) else { continue }
                var ref: EventHotKeyRef?
                let id = EventHotKeyID(signature: OSType(0x5253_5444), id: UInt32(i)) // 'RSTD'
                if RegisterEventHotKey(code, Self.carbonModifiers(s.modifiers), id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                    hotkeys.append(ref)
                } else {
                    failed.insert(action)
                }
            }
        }
        if failed != unavailable { unavailable = failed }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var ref: EventHandlerRef?
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let all = ShortcutAction.allCases, i = Int(id.id)
            if all.indices.contains(i) {
                let action = all[i]
                Task { @MainActor in ShortcutStore.fire(action) }
            }
            return noErr
        }, 1, &spec, nil, &ref)
        handler = ref
    }

    private static func fire(_ action: ShortcutAction) {
        switch action {
        case .newRecording:
            NSApp.activate()
            Studio.shared.newRecording()
        case .stopRecording:
            Task { await Studio.shared.stop() }
        case .pauseRecording:
            Studio.shared.togglePause()
        case .prompterHold:
            Teleprompter.shared.toggleHold()
        case .prompterBack:
            Teleprompter.shared.nudge(lines: -2)
        case .prompterForward:
            Teleprompter.shared.nudge(lines: 2)
        default:
            break
        }
    }

    /// The key code that types `s.key` on the current keyboard layout, so ⌃⌥⌘Z is the key marked Z on a QWERTZ keyboard too.
    private static func keyCode(_ s: Shortcut) -> UInt32? {
        if s.key.count == 1, let code = layoutKeyCode(typing: s.key) { return code }
        return s.keyCode
    }

    private static func layoutKeyCode(typing key: String) -> UInt32? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> UInt32? in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            for code in 0 ..< 128 {
                var dead: UInt32 = 0, length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, 4, &length, &chars)
                if status == noErr, length > 0, String(utf16CodeUnits: chars, count: length).lowercased() == key { return UInt32(code) }
            }
            return nil
        }
    }

    private static func carbonModifiers(_ m: Shortcut.Modifiers) -> UInt32 {
        var out = 0
        if m.contains(.command) { out |= cmdKey }
        if m.contains(.option) { out |= optionKey }
        if m.contains(.control) { out |= controlKey }
        if m.contains(.shift) { out |= shiftKey }
        return UInt32(out)
    }

    // MARK: Recording a new shortcut

    func record(_ action: ShortcutAction) {
        endRecording()
        recording = action
        problem = nil
        registerGlobal()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.typed(event) }
            return nil // nothing typed while recording reaches the window or the menus
        }
    }

    func endRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording != nil else { return }
        recording = nil
        problem = nil
        registerGlobal()
    }

    private func typed(_ event: NSEvent) {
        guard let action = recording else { return }
        if event.keyCode == UInt16(kVK_Escape), event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            endRecording() // Esc cancels
            return
        }
        guard let s = Shortcut(event: event) else {
            problem = "That key can't be used."
            NSSound.beep()
            return
        }
        if let p = ShortcutMap.problem(s, for: action) {
            problem = p
            NSSound.beep()
            return
        }
        endRecording()
        map[action] = s
    }
}

extension Shortcut {
    /// The shortcut a key press makes. Keys that type a character are named by it on the current layout;
    /// space, return, arrows and the like by their key code.
    init?(event e: NSEvent) {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: Modifiers = []
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.command) { mods.insert(.command) }
        if e.keyCode == UInt16(kVK_ForwardDelete) {
            self.init(key: "delete", modifiers: mods)
        } else if let named = Shortcut(keyCode: e.keyCode, modifiers: mods), named.key.count > 1 {
            self = named
        } else if let typed = e.characters(byApplyingModifiers: []), !typed.isEmpty {
            self.init(key: typed, modifiers: mods)
        } else {
            return nil
        }
    }
}

// MARK: Settings window

enum SettingsTab: String {
    case general, shortcuts, permissions, updates
    static let key = "settingsTab"
}

struct SettingsView: View {
    @AppStorage(Studio.countdownKey) private var countdown = 3
    @AppStorage(Studio.systemAudioKey) private var systemAudio = false
    @AppStorage(Studio.keystrokesKey) private var keystrokes = true
    @AppStorage(Studio.hideDesktopIconsKey) private var hideDesktopIcons = true
    @Bindable private var prompter = Teleprompter.shared
    @AppStorage(SettingsTab.key) private var tab = SettingsTab.general
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Tabs, so the window fits a 13" screen (1440×900) and Updates stays reachable as settings are added. Every tab is
    // the same grouped form: a heading with a line saying what the section is for, labels left, controls right.
    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: .general) {
                Form {
                    Section {
                        Picker("Countdown before recording", selection: $countdown) {
                            Text("Off").tag(0)
                            Text("3 seconds").tag(3)
                            Text("5 seconds").tag(5)
                        }
                        Toggle("Record system audio", isOn: $systemAudio)
                        Toggle("Show keyboard shortcuts in the video", isOn: $keystrokes)
                        Toggle("Hide desktop icons and widgets", isOn: $hideDesktopIcons)
                        Toggle("Show teleprompter while recording", isOn: $prompter.showsWhileRecording)
                    } header: {
                        SectionHeader("Recording", "The same switches as the record bar’s Options menu.")
                    }
                    Section {
                        Picker("Appearance", selection: $appearance) {
                            ForEach(AppAppearance.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .onChange(of: appearance) { AppAppearance.apply() }
                    } header: {
                        SectionHeader("Appearance", "Follow the system, or keep RecordStudio Light or Dark. Exports don’t change.")
                    }
                    Section {
                        Toggle("Show tips and next steps", isOn: Binding(get: { !TipStore.shared.state.tipsOff },
                                                                         set: { TipStore.shared.state.tipsOff = !$0 }))
                    } header: {
                        SectionHeader("Editor", "A checklist for your first recordings, and a tip the first time something new shows up. Help › Reset Tips shows them all again.")
                    }
                }
                .formStyle(.grouped)
                .fixedSize(horizontal: false, vertical: true)
            }
            Tab("Shortcuts", systemImage: "keyboard", value: .shortcuts) {
                Form {
                    ForEach(ShortcutGroup.allCases, id: \.self) { group in
                        Section {
                            ForEach(ShortcutAction.allCases.filter { $0.group == group }, id: \.self) { ShortcutRow(action: $0) }
                        } header: {
                            SectionHeader(group.title, group.detail)
                        }
                    }
                    Section {
                        LabeledContent("Esc always clears the selection.") {
                            Button("Restore Defaults") { ShortcutStore.shared.map = .defaults }
                                .disabled(ShortcutStore.shared.map == .defaults)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .frame(height: 600) // scrolls past this, so the window stays shorter than a laptop screen
            }
            Tab("Permissions", systemImage: "hand.raised", value: .permissions) {
                Form {
                    Section {
                        PermissionRows()
                    } header: {
                        SectionHeader("Permissions", "Only Screen Recording is required. The others turn on the microphone, the webcam bubble and the shortcuts shown in the video.")
                    }
                }
                .formStyle(.grouped)
                .fixedSize(horizontal: false, vertical: true)
            }
            Tab("Updates", systemImage: "arrow.triangle.2.circlepath", value: .updates) {
                Form { UpdateSettings() }
                    .formStyle(.grouped)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 520)
        .onChange(of: tab) { resizeSmoothly() }
        .onDisappear { ShortcutStore.shared.endRecording() }
    }

    /// SwiftUI sizes the window to the new tab in one jump. This lets it, then plays the change in height from the old
    /// size, the top edge staying put, as System Settings does. A clicked tab, so it animates; with Reduce Motion it
    /// stays a jump, since a cross-fade would only blur a size change.
    private func resizeSmoothly() {
        guard !reduceMotion, let window = NSApp.windows.first(where: { $0.isKeyWindow && $0.identifier?.rawValue.contains("Settings") == true }) else { return }
        let old = window.frame
        Task { @MainActor in
            let new = window.frame
            guard new.height != old.height else { return }
            window.setFrame(old, display: false)
            NSAnimationContext.animate(Motion.move) { window.setFrame(new, display: true) }
        }
    }
}

/// A settings section's heading, with a line under it saying what the section is for.
struct SectionHeader: View {
    let title: String, detail: String
    init(_ title: String, _ detail: String) { self.title = title; self.detail = detail }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(title).font(.headline).foregroundStyle(.primary)
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, Space.xxs)
    }
}

private struct ShortcutRow: View {
    let action: ShortcutAction

    var body: some View {
        let store = ShortcutStore.shared
        let isRecording = store.recording == action
        let warnings = store.map.conflicts(for: action) + (store.unavailable.contains(action) ? ["Another app already uses this shortcut, so it won't work."] : [])
        VStack(alignment: .leading, spacing: Space.xs) {
            LabeledContent(action.label) {
                HStack(spacing: Space.xs) {
                    // The keys as keycaps; click them and they turn into the recorder in place.
                    Button {
                        isRecording ? store.endRecording() : store.record(action)
                    } label: {
                        Group {
                            if isRecording {
                                Text("Type a shortcut…").foregroundStyle(.graphite).keycap(monospaced: false)
                            } else if let s = store.map[action] {
                                Keycaps(caps: s.caps)
                            } else {
                                Text("None").foregroundStyle(.secondary).keycap(monospaced: false)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .help(isRecording ? "Press the new shortcut, or Esc to cancel." : "Click, then press the new shortcut.")
                    Button {
                        store.map[action] = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this shortcut")
                    .opacity(store.map[action] == nil ? 0 : 1)
                    .disabled(store.map[action] == nil)
                }
            }
            if isRecording, let problem = store.problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            ForEach(warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
