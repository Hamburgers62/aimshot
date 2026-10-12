import AVFoundation
import Vision
import UIKit

enum GuideHint: Equatable {
    case none                              // no frame yet
    case move(dx: CGFloat, dy: CGFloat)    // where the frame centre is vs screen centre
    case aligned
    case lost
}

final class CameraModel: NSObject, ObservableObject {
    // MARK: UI state (main thread only)
    /// Target frame, normalized Vision coords (origin bottom-left, upright portrait).
    @Published var targetRect: CGRect? = nil
    @Published var hint: GuideHint = .none
    @Published var isScanning = false
    @Published var lastPhoto: UIImage? = nil
    @Published var toast: String? = nil
    @Published var permissionDenied = false

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "aimshot.session")
    private let videoQueue = DispatchQueue(label: "aimshot.video")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var configured = false
    private var photoDelegate: PhotoCaptureDelegate?
    private let haptic = UIImpactFeedbackGenerator(style: .medium)

    // MARK: Vision state (videoQueue only)
    /// Back camera frames arrive sideways; .right turns them upright for Vision.
    private let orientation: CGImagePropertyOrientation = .right
    private var sequenceHandler = VNSequenceRequestHandler()
    private var trackingRequest: VNTrackObjectRequest?
    private var pendingScan = false
    private var pendingStartRect: CGRect?
    private var frameCounter = 0
    private var wasAligned = false

    // MARK: Lifecycle

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    self.configureAndRun()
                } else {
                    DispatchQueue.main.async { self.permissionDenied = true }
                }
            }
        default:
            permissionDenied = true
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configureAndRun() {
        sessionQueue.async {
            if !self.configured {
                self.configureSession()
                self.configured = true
            }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        session.commitConfiguration()
    }

    // MARK: Actions from the UI

    /// Auto frame: look at the scene and pick the shot.
    func scan() {
        isScanning = true
        hint = .none
        targetRect = nil
        videoQueue.async {
            self.trackingRequest = nil
            self.pendingStartRect = nil
            self.pendingScan = true
        }
    }

    /// Your frame: the user drew a box (normalized Vision coords).
    func setCustomFrame(_ rect: CGRect) {
        videoQueue.async {
            self.pendingScan = false
            self.pendingStartRect = rect
        }
    }

    func clearFrame() {
        targetRect = nil
        hint = .none
        videoQueue.async {
            self.trackingRequest = nil
            self.pendingStartRect = nil
            self.pendingScan = false
        }
    }

    func capture() {
        let crop = targetRect
        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .balanced

        let delegate = PhotoCaptureDelegate { [weak self] data in
            guard let self = self else { return }
            self.photoDelegate = nil
            guard let data = data, let image = UIImage(data: data) else {
                self.showToast("Couldn't take the photo")
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let upright = image.normalizedUp()
                let final = crop.map { upright.cropped(toVisionRect: $0) } ?? upright
                let thumb = final.preparingThumbnail(of: CGSize(width: 240, height: 300)) ?? final
                DispatchQueue.main.async {
                    UIImageWriteToSavedPhotosAlbum(final, nil, nil, nil)
                    self.lastPhoto = thumb
                    self.showToast("Saved to Photos")
                }
            }
        }
        photoDelegate = delegate

        sessionQueue.async {
            if let conn = self.photoOutput.connection(with: .video) {
                if #available(iOS 17.0, *) {
                    if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
                } else {
                    if conn.isVideoOrientationSupported { conn.videoOrientation = .portrait }
                }
            }
            self.photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.toast == text { self?.toast = nil }
        }
    }

    // MARK: Tracking (videoQueue)

    private func startTracking(_ rect: CGRect) {
        let observation = VNDetectedObjectObservation(boundingBox: rect)
        let request = VNTrackObjectRequest(detectedObjectObservation: observation)
        request.trackingLevel = .accurate
        trackingRequest = request
        sequenceHandler = VNSequenceRequestHandler()
        wasAligned = false
        publish(rect)
    }

    private func publish(_ rect: CGRect) {
        let dx = rect.midX - 0.5
        let dy = rect.midY - 0.5
        // Hysteresis so the shutter doesn't flicker on the edge.
        let limit: CGFloat = wasAligned ? 0.06 : 0.035
        let aligned = abs(dx) < limit && abs(dy) < limit
        let justAligned = aligned && !wasAligned
        wasAligned = aligned

        DispatchQueue.main.async {
            self.targetRect = rect
            self.hint = aligned ? .aligned : .move(dx: dx, dy: dy)
            if justAligned { self.haptic.impactOccurred() }
        }
    }

    private func lose() {
        trackingRequest = nil
        wasAligned = false
        DispatchQueue.main.async {
            self.targetRect = nil
            self.hint = .lost
        }
    }
}

extension CameraModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameCounter += 1

        if pendingScan {
            pendingScan = false
            let rect = Composer.bestFrame(in: pixelBuffer, orientation: orientation)
            startTracking(rect)
            DispatchQueue.main.async { self.isScanning = false }
            return
        }

        if let rect = pendingStartRect {
            pendingStartRect = nil
            startTracking(rect)
            return
        }

        guard let request = trackingRequest else { return }
        if frameCounter % 2 != 0 { return }   // track every other frame to save battery

        do {
            try sequenceHandler.perform([request], on: pixelBuffer, orientation: orientation)
        } catch {
            lose()
            return
        }
        guard let observation = request.results?.first, observation.confidence > 0.3 else {
            lose()
            return
        }
        request.inputObservation = observation
        publish(observation.boundingBox)
    }
}

final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Data?) -> Void

    init(completion: @escaping (Data?) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        DispatchQueue.main.async { self.completion(data) }
    }
}

extension UIImage {
    /// Redraws the image so its pixels are upright (no EXIF rotation left).
    func normalizedUp() -> UIImage {
        if imageOrientation == .up { return self }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// Crops to a normalized Vision rect (origin bottom-left). Expects an upright image.
    func cropped(toVisionRect r: CGRect) -> UIImage {
        guard let cg = cgImage else { return self }
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        let rect = CGRect(x: r.minX * w, y: (1 - r.maxY) * h, width: r.width * w, height: r.height * h)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !rect.isEmpty, let cropped = cg.cropping(to: rect) else { return self }
        return UIImage(cgImage: cropped, scale: 1, orientation: .up)
    }
}
