import Foundation

/// A key plus modifiers, stored as text like "ctrl+opt+cmd+r" or "space".
/// `key` is the character the key types on the user's layout (lowercased), or a name for keys that don't type one.
public struct Shortcut: Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    public var key: String
    public var modifiers: Modifiers

    public init?(key: String, modifiers: Modifiers = []) {
        let key = key.lowercased()
        guard Shortcut.keyCodes[key] != nil || Shortcut.isTypedCharacter(key) else { return nil }
        self.key = key
        self.modifiers = modifiers
    }

    /// Parses "ctrl+opt+cmd+r", in any order and case. Nil for unknown keys or modifiers.
    public init?(_ text: String) {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, !key.isEmpty else { return nil }
        var mods: Modifiers = []
        for p in parts.dropLast() {
            switch p {
            case "ctrl", "control": mods.insert(.control)
            case "opt", "option", "alt": mods.insert(.option)
            case "shift": mods.insert(.shift)
            case "cmd", "command": mods.insert(.command)
            default: return nil
            }
        }
        self.init(key: key, modifiers: mods)
    }

    /// Looks a physical key code up (from NSEvent.keyCode).
    public init?(keyCode: UInt16, modifiers: Modifiers) {
        guard let key = Shortcut.keyCodes.first(where: { $0.value == UInt32(keyCode) })?.key else { return nil }
        self.init(key: key, modifiers: modifiers)
    }

    /// The stored form, modifiers in the order macOS shows them.
    public var text: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        return (parts + [key]).joined(separator: "+")
    }

    /// What menus show, e.g. "⌃⌥⌘R" or "Space".
    public var symbol: String { caps.joined() }

    /// One label per key to press, as keycaps show them: ["⌃", "⌥", "⌘", "Space"].
    public var caps: [String] {
        var c: [String] = []
        if modifiers.contains(.control) { c.append("⌃") }
        if modifiers.contains(.option) { c.append("⌥") }
        if modifiers.contains(.shift) { c.append("⇧") }
        if modifiers.contains(.command) { c.append("⌘") }
        let names = ["space": "Space", "return": "↩", "tab": "⇥", "delete": "⌫", "escape": "⎋",
                     "left": "←", "right": "→", "up": "↑", "down": "↓", "home": "Home", "end": "End"]
        return c + [names[key] ?? key.uppercased()]
    }

    /// The virtual key code on a US layout. The app looks typed characters up on the current layout first.
    public var keyCode: UInt32? { Shortcut.keyCodes[key] }

    /// One visible character, like "ž" on a Bosnian layout. Names like "space" are handled by `keyCodes`.
    static func isTypedCharacter(_ s: String) -> Bool {
        guard s.count == 1, let c = s.unicodeScalars.first else { return false }
        return !CharacterSet.whitespacesAndNewlines.union(.controlCharacters).union(.uppercaseLetters).contains(c)
    }

    /// True when it has ⌘, ⌥ or ⌃, which a system-wide shortcut needs so it doesn't swallow ordinary typing.
    public var isSafeGlobally: Bool { !modifiers.isDisjoint(with: [.command, .option, .control]) }

    static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "l": 37, "j": 38, "'": 39,
        "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
        "delete": 51, "escape": 53, "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100, "f9": 101, "f11": 103, "f10": 109,
        "f12": 111, "f4": 118, "f2": 120, "f1": 122, "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119,
    ]
}

/// Everything a shortcut can be bound to. Global ones work from any app; the rest only in the editor.
public enum ShortcutAction: String, CaseIterable, Sendable {
    case newRecording, stopRecording, pauseRecording, prompterHold, prompterBack, prompterForward
    case play, setIn, setOut, delete, addZoom, split, addMarker, addText
    case frameBack, frameForward, secondBack, secondForward, previousEdit, nextEdit, playBackward, stop, playForward, toStart, toEnd

    public var label: String {
        switch self {
        case .newRecording: "New Recording"
        case .stopRecording: "Stop Recording"
        case .pauseRecording: "Pause / Resume Recording"
        case .prompterHold: "Pause / Resume Teleprompter"
        case .prompterBack: "Teleprompter Back"
        case .prompterForward: "Teleprompter Forward"
        case .play: "Play / Pause"
        case .setIn: "Set Trim Start"
        case .setOut: "Set Trim End"
        case .delete: "Delete Selected Zoom, Annotation, Chapter or Segment"
        case .addZoom: "Add Zoom at Playhead"
        case .split: "Split Clip at Playhead"
        case .addMarker: "Add Chapter at Playhead"
        case .addText: "Add Text at Playhead"
        case .frameBack: "Back One Frame"
        case .frameForward: "Forward One Frame"
        case .secondBack: "Back One Second"
        case .secondForward: "Forward One Second"
        case .previousEdit: "Previous Edit Point"
        case .nextEdit: "Next Edit Point"
        case .playBackward: "Play Backward (Again: Faster)"
        case .stop: "Stop"
        case .playForward: "Play Forward (Again: Faster)"
        case .toStart: "Go to Start"
        case .toEnd: "Go to End"
        }
    }

    /// Where it works, as Settings › Shortcuts groups them.
    public var group: ShortcutGroup {
        switch self {
        case .newRecording: .anywhere
        case .stopRecording, .pauseRecording, .prompterHold, .prompterBack, .prompterForward: .recording
        case .play, .setIn, .setOut, .delete, .addZoom, .split, .addMarker, .addText: .editor
        default: .timeline
        }
    }

    public var isGlobal: Bool { [.newRecording, .stopRecording, .pauseRecording, .prompterHold, .prompterBack, .prompterForward].contains(self) }
}

/// The user's bindings. An action missing from `bindings` has no shortcut.
public struct ShortcutMap: Equatable, Sendable {
    public var bindings: [ShortcutAction: Shortcut]

    public init(bindings: [ShortcutAction: Shortcut]) { self.bindings = bindings }

    public static let defaults = ShortcutMap(bindings: [
        .newRecording: Shortcut("ctrl+opt+cmd+r")!,
        .stopRecording: Shortcut("ctrl+opt+cmd+s")!,
        .pauseRecording: Shortcut("ctrl+opt+cmd+p")!,
        .prompterHold: Shortcut("ctrl+opt+cmd+space")!,
        .prompterBack: Shortcut("ctrl+opt+cmd+up")!,
        .prompterForward: Shortcut("ctrl+opt+cmd+down")!,
        .play: Shortcut("space")!,
        .setIn: Shortcut("i")!,
        .setOut: Shortcut("o")!,
        .delete: Shortcut("delete")!,
        .addZoom: Shortcut("z")!,
        .split: Shortcut("s")!,
        .addMarker: Shortcut("m")!,
        .addText: Shortcut("t")!,
        .frameBack: Shortcut("left")!,
        .frameForward: Shortcut("right")!,
        .secondBack: Shortcut("shift+left")!,
        .secondForward: Shortcut("shift+right")!,
        .previousEdit: Shortcut("up")!,
        .nextEdit: Shortcut("down")!,
        .playBackward: Shortcut("j")!,
        .stop: Shortcut("k")!,
        .playForward: Shortcut("l")!,
        .toStart: Shortcut("home")!,
        .toEnd: Shortcut("end")!,
    ])

    /// Shortcuts the app's own menus use, which a binding would clash with.
    public static let menuShortcuts: [Shortcut: String] = [
        Shortcut("cmd+n")!: "New Recording…", Shortcut("cmd+.")!: "Stop Recording", Shortcut("cmd+e")!: "Export",
        Shortcut("cmd+,")!: "Settings", Shortcut("cmd+q")!: "Quit", Shortcut("cmd+w")!: "Close", Shortcut("cmd+h")!: "Hide",
        Shortcut("cmd+m")!: "Minimize", Shortcut("shift+cmd+i")!: "Insert Clip…", Shortcut("cmd+o")!: "Open Project…",
        Shortcut("shift+cmd+o")!: "Import Video…", Shortcut("shift+cmd+s")!: "Save Project As…", Shortcut("cmd+z")!: "Undo",
        Shortcut("shift+cmd+z")!: "Redo", Shortcut("cmd+x")!: "Cut", Shortcut("cmd+c")!: "Copy", Shortcut("cmd+v")!: "Paste",
        Shortcut("cmd+d")!: "Duplicate", Shortcut("cmd+a")!: "Select All", Shortcut("opt+cmd+i")!: "Show / Hide Inspector",
        Shortcut("cmd+/")!: "Keyboard Shortcuts", Shortcut("cmd+=")!: "Zoom Timeline In",
        Shortcut("cmd+-")!: "Zoom Timeline Out", Shortcut("cmd+0")!: "Fit Timeline to Window",
    ].merging((1...9).map { (Shortcut("cmd+\($0)")!, "Inspector Tab \($0)") }) { a, _ in a }

    public subscript(_ a: ShortcutAction) -> Shortcut? {
        get { bindings[a] }
        set { bindings[a] = newValue }
    }

    /// The editor action a key press triggers, if any.
    public func editorAction(for s: Shortcut) -> ShortcutAction? {
        ShortcutAction.allCases.first { !$0.isGlobal && bindings[$0] == s }
    }

    /// For UserDefaults: action name → shortcut text, "" for an action the user unbound.
    public var stored: [String: String] {
        Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0.rawValue, bindings[$0]?.text ?? "") })
    }

    /// Reads what `stored` wrote. Actions that are missing or unreadable get their default.
    public init(stored: [String: String]) {
        var b = ShortcutMap.defaults.bindings
        for a in ShortcutAction.allCases {
            guard let text = stored[a.rawValue] else { continue }
            if text.isEmpty { b[a] = nil } else if let s = Shortcut(text) { b[a] = s }
        }
        bindings = b
    }

    /// Why `s` can't be used for `a`, or nil when it can.
    public static func problem(_ s: Shortcut, for a: ShortcutAction) -> String? {
        if a.isGlobal, !s.isSafeGlobally { return "Global shortcuts need ⌘, ⌥ or ⌃, or they'd swallow ordinary typing in every app." }
        if s.key == "escape" { return "Esc is reserved for cancelling." }
        return nil
    }

    /// Every shortcut by where it works, for the shortcuts overlay: the user's own bindings group by group (unbound ones
    /// left out), Esc, then the menus' shortcuts by name with the inspector's tabs named as the View menu has them.
    public func overview(tabs: [String]) -> [(title: String, items: [(label: String, shortcut: Shortcut)])] {
        var out = ShortcutGroup.allCases.map { g in
            (title: g.title, items: ShortcutAction.allCases.filter { $0.group == g }.compactMap { a in bindings[a].map { (label: a.label, shortcut: $0) } })
        }
        if let i = out.firstIndex(where: { $0.title == ShortcutGroup.editor.title }) { out[i].items.append((label: "Clear Selection", shortcut: Shortcut("escape")!)) }
        let menus = ShortcutMap.menuShortcuts.filter { !$0.value.hasPrefix("Inspector Tab") }.map { (label: $0.value, shortcut: $0.key) }
            + tabs.prefix(9).enumerated().map { (label: "Inspector: \($1)", shortcut: Shortcut("cmd+\($0 + 1)")!) }
        out.append((title: "Menus", items: menus.sorted { $0.label < $1.label }))
        return out.filter { !$0.items.isEmpty }
    }

    /// Warnings for the action's current binding: other actions with the same keys, or a menu shortcut.
    public func conflicts(for a: ShortcutAction) -> [String] {
        guard let s = bindings[a] else { return [] }
        var out = ShortcutAction.allCases.filter { $0 != a && bindings[$0] == s }.map { "Also set for \($0.label)." }
        if let menu = ShortcutMap.menuShortcuts[s] { out.append("Also the menu shortcut for \(menu).") }
        if a.isGlobal, s.modifiers == [.command] { out.append("\(s.symbol) is used by most apps; RecordStudio would take it from them.") }
        return out
    }
}

/// Where a shortcut works, in the order Settings shows the groups.
public enum ShortcutGroup: CaseIterable, Sendable {
    case anywhere, recording, editor, timeline

    public var title: String {
        switch self {
        case .anywhere: "Anywhere"
        case .recording: "While Recording"
        case .editor: "Editor"
        case .timeline: "Moving Around the Timeline"
        }
    }

    public var detail: String {
        switch self {
        case .anywhere: "Works from any app, even when RecordStudio is in the background."
        case .recording: "Work from any app while you record or the teleprompter is showing."
        case .editor: "Work in the editor, on the selection or at the playhead."
        case .timeline: "Move the playhead and play in either direction."
        }
    }
}
