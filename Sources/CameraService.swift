import AVFoundation
import CoreMedia
import Foundation

/// Owns the AVCaptureSession. Frames arrive on `frameQueue`; the camera is fully stopped when not needed.
final class CameraService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let frameQueue = DispatchQueue(label: "steady.camera.frames", qos: .userInitiated)
    private let sessionQueue = DispatchQueue(label: "steady.camera.session")
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private var currentInput: AVCaptureDeviceInput?
    private var configured = false

    /// Called on `frameQueue` for every delivered frame.
    var onFrame: ((CVPixelBuffer, Double) -> Void)?
    /// Called on the main thread when the camera starts or stops: (running, device name).
    var onStateChange: ((Bool, String) -> Void)?

    static func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    /// The selected camera, or the built-in one. A Continuity Camera iPhone is never picked silently.
    static func device(for id: String?) -> AVCaptureDevice? {
        let all = availableDevices()
        if let id, let match = all.first(where: { $0.uniqueID == id }) { return match }
        return AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video,
                                                position: .unspecified).devices.first
            ?? all.first(where: { $0.deviceType != .continuityCamera })
    }

    func requestAccess(completion: @escaping (AVAuthorizationStatus) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { _ in
                DispatchQueue.main.async { completion(AVCaptureDevice.authorizationStatus(for: .video)) }
            }
        } else {
            completion(status)
        }
    }

    func start(deviceID: String?) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let device = Self.device(for: deviceID) else {
                EventLog.shared.add(.info, nil, "No camera found")
                return
            }
            if !self.configured || self.currentInput?.device.uniqueID != device.uniqueID {
                self.configure(device: device)
            }
            if !self.session.isRunning {
                self.session.startRunning()
                EventLog.shared.add(.info, nil, "Camera on: \(device.localizedName)")
            }
            let running = self.session.isRunning
            let name = device.localizedName
            DispatchQueue.main.async { self.onStateChange?(running, name) }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
                EventLog.shared.add(.info, nil, "Camera off")
            }
            let name = self.currentInput?.device.localizedName ?? ""
            DispatchQueue.main.async { self.onStateChange?(false, name) }
        }
    }

    private func configure(device: AVCaptureDevice) {
        session.beginConfiguration()
        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        }
        if let currentInput { session.removeInput(currentInput) }
        currentInput = nil
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                currentInput = input
            }
        } catch {
            EventLog.shared.add(.info, nil, "Camera could not open: \(error.localizedDescription)")
        }
        if !configured {
            // The camera's native YUV format: Vision reads it directly and motion uses the luma plane,
            // which costs much less CPU than converting every frame to BGRA.
            // Ask for 640x480 explicitly: on recent macOS the capture pipeline can deliver 1080p frames
            // even with a VGA preset, which costs much more CPU and memory.
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferWidthKey as String: 640,
                kCVPixelBufferHeightKey as String: 480
            ]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: frameQueue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        // Keep frames unmirrored, so clips show the view other people have.
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        session.commitConfiguration()

        // Pick the smallest 4:3 format of at least 640x480 directly on the device, and ask for 15 fps.
        // Locking the device switches the session to input priority, so the preset alone isn't enough.
        do {
            try device.lockForConfiguration()
            let candidates = device.formats.filter { f in
                let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                return d.width >= 640 && d.height >= 480 && d.width * 3 == d.height * 4
            }
            if let best = candidates.min(by: {
                CMVideoFormatDescriptionGetDimensions($0.formatDescription).width < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
            }) {
                device.activeFormat = best
            }
            let target = CMTime(value: 1, timescale: 15)
            if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameDuration <= target && $0.maxFrameDuration >= target }) {
                device.activeVideoMinFrameDuration = target
                device.activeVideoMaxFrameDuration = target
            }
            device.unlockForConfiguration()
            let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            EventLog.shared.add(.info, nil, "Camera format \(dims.width)x\(dims.height)")
        } catch {
            // The camera's default format also works; frames are throttled later.
        }
        configured = true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // One monotonic clock for the whole app, so feedback windows and alerts line up.
        onFrame?(pixelBuffer, monotonicNow())
    }
}

/// Monotonic time in seconds, safe to call from any thread.
func monotonicNow() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1e9
}
