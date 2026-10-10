import Foundation

/// The macOS permissions RecordStudio asks for. Only Screen Recording is required; the rest turn on optional features.
public enum Permission: String, CaseIterable, Sendable {
    case screenRecording, microphone, camera, inputMonitoring, accessibility

    public var title: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .microphone: "Microphone"
        case .camera: "Camera"
        case .inputMonitoring: "Input Monitoring"
        case .accessibility: "Accessibility"
        }
    }

    public var purpose: String {
        switch self {
        case .screenRecording: "Required, to record your screen."
        case .microphone: "To record your voice."
        case .camera: "For the webcam bubble."
        case .inputMonitoring: "To show the shortcuts you press."
        case .accessibility: "To resize a window to a video size before recording it."
        }
    }

    public var isRequired: Bool { self == .screenRecording }

    /// macOS applies these to a running app only once it relaunches.
    public var appliesAfterRelaunch: Bool { self == .screenRecording || self == .inputMonitoring }

    /// The permission's page in System Settings › Privacy & Security.
    public var settingsURL: URL {
        let anchor = switch self {
        case .screenRecording: "Privacy_ScreenCapture"
        case .microphone: "Privacy_Microphone"
        case .camera: "Privacy_Camera"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .accessibility: "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

public enum PermissionState: Sendable {
    case allowed, denied, notAsked

    /// What the permission's button does: macOS shows its own prompt only once, so after that only System Settings can
    /// change the answer.
    public var action: PermissionAction? {
        switch self {
        case .allowed: nil
        case .denied: .openSettings
        case .notAsked: .ask
        }
    }
}

public enum PermissionAction: Sendable { case ask, openSettings }
