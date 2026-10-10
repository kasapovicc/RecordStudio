import AVFoundation
import Foundation

public struct CameraDevice: Identifiable, Hashable, Sendable {
    public var id: String, name: String
    public var isPhone: Bool
}

/// The webcam: a live session that feeds the on-screen preview bubble and, while recording, a movie file.
/// macOS video effects (Edge Light, Studio Light, Portrait, Center Stage) apply to this session's frames.
public final class CameraRig: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    public let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "RecordStudio.camera")
    private var input: AVCaptureDeviceInput?
    private var started: CheckedContinuation<Double, Error>?
    private var finished: CheckedContinuation<Void, Error>?
    public private(set) var deviceID: String?

    /// Mac cameras, iPhones via Continuity Camera, and USB cameras.
    public static func devices() -> [CameraDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external], mediaType: .video, position: .unspecified)
            .devices.map { CameraDevice(id: $0.uniqueID, name: $0.localizedName, isPhone: $0.deviceType == .continuityCamera) }
    }

    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Switches to a camera (or none) and starts/stops the live session.
    public func use(_ id: String?) async throws {
        if id != nil, !(await Self.requestAccess()) {
            throw StudioError.message("RecordStudio needs Camera access. Turn it on in System Settings › Privacy & Security › Camera.")
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    session.beginConfiguration()
                    if let input { session.removeInput(input); self.input = nil }
                    if let id {
                        guard let device = AVCaptureDevice(uniqueID: id) else { throw StudioError.message("That camera isn't connected any more.") }
                        let input = try AVCaptureDeviceInput(device: device)
                        guard session.canAddInput(input) else { throw StudioError.message("\(device.localizedName) is busy in another app.") }
                        session.addInput(input)
                        self.input = input
                        if session.outputs.isEmpty, session.canAddOutput(output) { session.addOutput(output) }
                        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
                    }
                    session.commitConfiguration()
                    if id == nil { if session.isRunning { session.stopRunning() } } else if !session.isRunning { session.startRunning() }
                    deviceID = id
                    c.resume()
                } catch {
                    session.commitConfiguration()
                    c.resume(throwing: error)
                }
            }
        }
    }

    public var isActive: Bool { deviceID != nil }

    /// Starts writing the camera to `url`. Returns the host time (CACurrentMediaTime) of the first written frame.
    public func startRecording(to url: URL) async throws -> Double {
        try? FileManager.default.removeItem(at: url)
        return try await withCheckedThrowingContinuation { c in
            started = c
            queue.async { [self] in output.startRecording(to: url, recordingDelegate: self) }
        }
    }

    public func stopRecording() async throws {
        guard output.isRecording else { return }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            finished = c
            queue.async { [self] in output.stopRecording() }
        }
    }

    /// Holds the camera file while the recording is paused; nothing is written until `resumeRecording`.
    public func pauseRecording() {
        queue.async { [self] in if output.isRecording, !output.isRecordingPaused { output.pauseRecording() } }
    }

    public func resumeRecording() {
        queue.async { [self] in if output.isRecordingPaused { output.resumeRecording() } }
    }

    /// Opens the system Video Effects panel (Edge Light, Studio Light, Portrait, Center Stage…).
    public static func showVideoEffects() { AVCaptureDevice.showSystemUserInterface(.videoEffects) }

    public func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        let now = CACurrentMediaTime()
        let c = started; started = nil
        c?.resume(returning: now)
    }

    public func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        // AVFoundation reports a normal stop as an "error" with this flag set.
        let ok = error == nil || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false)
        if let c = started { started = nil; c.resume(throwing: error ?? StudioError.message("The camera stopped before recording began.")) }
        let c = finished; finished = nil
        if ok { c?.resume() } else { c?.resume(throwing: error!) }
    }
}

/// Timing stored next to a separately recorded file (camera.json, system.json): the file's time 0 is `offset` seconds
/// into the screen recording.
public struct CameraSync: Codable, Sendable {
    public var offset: Double
}
