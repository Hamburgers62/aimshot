import AVFoundation
import CoreImage
import CoreMotion
import ImageIO
import UIKit
import simd

enum Phase: Equatable {
    case idle       // no target
    case scanning   // waiting for the AI
    case guiding    // target set, aim at it
    case zooming    // centred, zooming in to fill the frame
    case ready      // framed up, shoot
}

final class CameraModel: NSObject, ObservableObject {
    // MARK: UI state (main thread only)
    @Published var phase: Phase = .idle
    @Published var target: AimTarget? = nil
    /// Where the target is in the view right now (normalized Vision coords, origin bottom-left).
    @Published var frameRect: CGRect? = nil
    @Published var hint: String = "Tap ✦ to scan the scene"
    @Published var roll: Double = 0
    @Published var displayZoom: Double = 1
    @Published var zoomStops: [Double] = [1]
    @Published var shootProgress: Double = 0
    @Published var lastPhoto: UIImage? = nil
    @Published var toast: String? = nil
    @Published var permissionDenied = false
    @Published var isShooting = false
    @Published var flash = false

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "aimshot.session")
    private let videoQueue = DispatchQueue(label: "aimshot.video")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var configured = false
    private var photoDelegate: PhotoCaptureDelegate?
    private var zoomObservation: NSKeyValueObservation?
    private let ciContext = CIContext()

    // MARK: Motion + geometry (main thread)
    private let motion = CMMotionManager()
    private var geometry = CameraGeometry(tanHalfW: 0.55, tanHalfH: 0.73)
    private var attitude: simd_double3x3 = matrix_identity_double3x3
    private var zoomFactor: Double = 1      // mirrors device.videoZoomFactor
    private var uwFactor: Double = 1        // zoom factor that equals "1x"
    private var minZoom: Double = 1
    private var maxZoom: Double = 10
    private var scanZoom: Double = 1
    private var targetZoom: Double? = nil
    private var lastZoomCommand: Double? = nil
    private var steadySince: Date? = nil
    private var scanToken = 0

    // MARK: Snapshot (videoQueue only)
    private var snapshotHandler: ((CVPixelBuffer) -> Void)?

    // MARK: Lifecycle

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { self.run() } else { self.permissionDenied = true }
                }
            }
        default:
            permissionDenied = true
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func run() {
        startMotion()
        sessionQueue.async {
            if !self.configured {
                self.configureSession()
                self.configured = true
            }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    private static func pickBackCamera() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera
        ]
        for type in types {
            if let d = AVCaptureDevice.default(type, for: .video, position: .back) { return d }
        }
        return nil
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let device = Self.pickBackCamera(),
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
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        session.commitConfiguration()
        self.device = device
        setUpZoom(for: device)
    }

    /// Works out the lenses, zoom buttons and field of view. Runs on sessionQueue.
    private func setUpZoom(for device: AVCaptureDevice) {
        let switches = device.virtualDeviceSwitchOverVideoZoomFactors.map { $0.doubleValue }
        let hasUltraWide = device.deviceType == .builtInTripleCamera || device.deviceType == .builtInDualWideCamera
        let hasTele = device.deviceType == .builtInTripleCamera || device.deviceType == .builtInDualCamera
        let uw = hasUltraWide ? (switches.first ?? 1) : 1

        var stops: [Double] = []
        if hasUltraWide { stops.append(1 / uw) }
        stops.append(1)
        stops.append(2)
        if hasTele, let tele = switches.last { stops.append(tele / uw) }
        stops = Array(Set(stops.map { ($0 * 10).rounded() / 10 })).sorted()

        // Field of view at zoom factor 1, for the upright portrait view.
        var fovDeg = Double(device.activeFormat.videoFieldOfView)
        if fovDeg < 20 { fovDeg = 70 }
        var tanLong = tan(fovDeg / 2 * .pi / 180)
        if hasUltraWide && fovDeg < 95 {
            // Reported the 1x lens rather than the ultra-wide: widen to zoom factor 1.
            tanLong *= uw
        }
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let shortSide = Double(min(dims.width, dims.height))
        let longSide = Double(max(dims.width, dims.height))
        let ratio = longSide > 0 ? shortSide / longSide : 0.75
        let geo = CameraGeometry(tanHalfW: tanLong * ratio, tanHalfH: tanLong)

        let minZ = Double(device.minAvailableVideoZoomFactor)
        let maxZ = min(Double(device.maxAvailableVideoZoomFactor), uw * 15)

        // Start at the widest lens, so a scan sees the whole room.
        if (try? device.lockForConfiguration()) != nil {
            device.videoZoomFactor = CGFloat(minZ)
            device.unlockForConfiguration()
        }

        DispatchQueue.main.async {
            self.geometry = geo
            self.uwFactor = uw
            self.minZoom = minZ
            self.maxZoom = maxZ
            self.scanZoom = minZ
            self.zoomStops = stops
        }

        zoomObservation = device.observe(\.videoZoomFactor, options: [.initial, .new]) { [weak self] dev, _ in
            let z = Double(dev.videoZoomFactor)
            DispatchQueue.main.async { self?.zoomChanged(z) }
        }
    }

    private func zoomChanged(_ z: Double) {
        zoomFactor = z
        let display = z / uwFactor
        if abs(display - displayZoom) > 0.01 { displayZoom = display }
    }

    // MARK: Zoom

    func selectZoom(_ display: Double) {
        targetZoom = nil
        if phase == .zooming || phase == .ready { phase = .guiding }
        rampZoom(to: display * uwFactor, rate: 8)
    }

    private func rampZoom(to factor: Double, rate: Float) {
        let f = min(max(factor, minZoom), maxZoom)
        if let last = lastZoomCommand, abs(last - f) < 0.001 { return }
        lastZoomCommand = f
        sessionQueue.async {
            guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            d.ramp(toVideoZoomFactor: CGFloat(f), withRate: rate)
            d.unlockForConfiguration()
        }
    }

    private func stopZoomRamp() {
        lastZoomCommand = nil
        sessionQueue.async {
            guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            d.cancelVideoZoomRamp()
            d.unlockForConfiguration()
        }
    }

    // MARK: Motion

    private func startMotion() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] m, _ in
            guard let self = self, let m = m else { return }
            self.motionUpdate(m)
        }
    }

    private func motionUpdate(_ m: CMDeviceMotion) {
        AimMath.learnConvention(from: m)
        attitude = AimMath.matrix(m.attitude.rotationMatrix)

        let newRoll = atan2(m.gravity.x, -m.gravity.y)
        if abs(newRoll - roll) > 0.003 { roll = newRoll }

        let rr = m.rotationRate
        let spin = sqrt(rr.x * rr.x + rr.y * rr.y + rr.z * rr.z)
        updateGuide(spin: spin)
    }

    // MARK: Guiding

    private func updateGuide(spin: Double) {
        guard let t = target, phase != .idle, phase != .scanning else { return }

        guard let rect = AimMath.project(t, r: attitude, zoom: zoomFactor, geo: geometry),
              rect.midX > -0.5, rect.midX < 1.5, rect.midY > -0.5, rect.midY < 1.5 else {
            // Target is way out of view: zoom back out and point the way.
            if frameRect != nil { frameRect = nil }
            if phase != .guiding { phase = .guiding; targetZoom = nil }
            if zoomFactor > scanZoom * 1.05 { rampZoom(to: scanZoom, rate: 4) }
            resetShootTimer()
            setHint(offscreenHint(t))
            return
        }
        frameRect = rect

        let dx = Double(rect.midX) - 0.5
        let dy = Double(rect.midY) - 0.5
        let tolX = max(0.03, 0.15 * Double(rect.width))
        let tolY = max(0.03, 0.15 * Double(rect.height))
        let centred = abs(dx) < tolX && abs(dy) < tolY
        let loose = abs(dx) < 3 * tolX && abs(dy) < 3 * tolY

        switch phase {
        case .guiding:
            if centred {
                let z = min(max(AimMath.fillZoom(for: t, geo: geometry), minZoom), maxZoom)
                targetZoom = z
                phase = .zooming
                rampZoom(to: z, rate: 2.5)
                haptic(.light)
            }
        case .zooming:
            if !loose {
                phase = .guiding
                targetZoom = nil
                stopZoomRamp()
            } else if let tz = targetZoom, abs(zoomFactor - tz) < 0.03 * tz {
                phase = .ready
                haptic(.medium)
            }
        case .ready:
            if !loose {
                phase = .guiding
                targetZoom = nil
            }
        default:
            break
        }

        switch phase {
        case .guiding:
            var parts: [String] = []
            if abs(dx) > tolX { parts.append(dx > 0 ? "right" : "left") }
            if abs(dy) > tolY { parts.append(dy > 0 ? "up" : "down") }
            setHint(parts.isEmpty ? "Hold it there…" : "Aim \(parts.joined(separator: " and ")) at the \(t.subject)")
        case .zooming:
            setHint("Centered — framing up…")
        case .ready:
            setHint(t.why)
        default:
            break
        }

        // Auto-shoot once it's framed and you're holding still.
        if phase == .ready {
            if spin < 0.25 {
                if steadySince == nil { steadySince = Date() }
            } else {
                steadySince = nil
            }
            let held = steadySince.map { Date().timeIntervalSince($0) } ?? 0
            let auto = UserDefaults.standard.object(forKey: "autoShoot") as? Bool ?? true
            let progress = auto ? min(held / 0.8, 1) : 0
            if abs(progress - shootProgress) > 0.02 || (progress == 0 && shootProgress != 0) {
                shootProgress = progress
            }
            if auto && held >= 0.8 && !isShooting { capture() }
        } else {
            resetShootTimer()
        }
    }

    private func resetShootTimer() {
        steadySince = nil
        if shootProgress != 0 { shootProgress = 0 }
    }

    private func offscreenHint(_ t: AimTarget) -> String {
        let v = AimMath.toDevice(t.worldDir, attitude)
        if v.z > 0 { return "Turn around to find the \(t.subject)" }
        var parts: [String] = []
        if abs(v.x) > abs(v.y) * 0.5 { parts.append(v.x > 0 ? "right" : "left") }
        if abs(v.y) > abs(v.x) * 0.5 { parts.append(v.y > 0 ? "up" : "down") }
        return "Turn \(parts.joined(separator: " and ")) to the \(t.subject)"
    }

    private func setHint(_ s: String) {
        if hint != s { hint = s }
    }

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        DispatchQueue.main.async { UIImpactFeedbackGenerator(style: style).impactOccurred() }
    }

    // MARK: Scan

    func scan() {
        guard phase != .scanning else { return }
        clearTarget(resetZoom: false)
        scanToken += 1
        let token = scanToken
        phase = .scanning
        setHint("Looking for the best shot…")

        let r0 = attitude
        let z0 = zoomFactor
        let geo = geometry
        scanZoom = zoomFactor
        let key = KeyStore.load()
        let model = UserDefaults.standard.string(forKey: "aiModel") ?? AIModel.sonnet.rawValue

        requestSnapshot { [weak self] buffer in
            guard let self = self else { return }

            if key.isEmpty {
                let rect = Composer.bestFrame(in: buffer, orientation: .right)
                DispatchQueue.main.async {
                    guard token == self.scanToken else { return }
                    self.setTarget(rect: rect, r: r0, zoom: z0, geo: geo,
                                   subject: "interesting spot",
                                   why: "basic guess, add an API key for smart picks")
                }
                return
            }

            guard let snap = self.makeJPEG(buffer) else {
                DispatchQueue.main.async { self.scanFailed("Couldn't read the camera", token: token) }
                return
            }

            Task {
                do {
                    let idea = try await AIScout.findShot(jpeg: snap.data, width: snap.width, height: snap.height,
                                                          apiKey: key, model: model)
                    await MainActor.run {
                        guard token == self.scanToken else { return }
                        self.setTarget(rect: idea.rect, r: r0, zoom: z0, geo: geo,
                                       subject: idea.subject, why: idea.why)
                    }
                } catch {
                    await MainActor.run { self.scanFailed(error.localizedDescription, token: token) }
                }
            }
        }
    }

    private func scanFailed(_ message: String, token: Int) {
        guard token == scanToken else { return }
        phase = .idle
        setHint("Tap ✦ to scan the scene")
        showToast(message)
    }

    /// Your own frame: the user drew a box (normalized Vision coords).
    func setCustomFrame(_ rect: CGRect) {
        clearTarget(resetZoom: false)
        scanZoom = zoomFactor
        setTarget(rect: rect, r: attitude, zoom: zoomFactor, geo: geometry,
                  subject: "your frame", why: "your shot, hold steady")
    }

    private func setTarget(rect: CGRect, r: simd_double3x3, zoom: Double, geo: CameraGeometry,
                           subject: String, why: String) {
        target = AimMath.target(from: rect, r: r, zoom: zoom, geo: geo, subject: subject, why: why)
        targetZoom = nil
        phase = .guiding
        haptic(.light)
        updateGuide(spin: 1)
    }

    func clearTarget(resetZoom: Bool = true) {
        scanToken += 1
        target = nil
        frameRect = nil
        targetZoom = nil
        resetShootTimer()
        phase = .idle
        setHint("Tap ✦ to scan the scene")
        if resetZoom { rampZoom(to: scanZoom, rate: 6) }
    }

    private func requestSnapshot(_ handler: @escaping (CVPixelBuffer) -> Void) {
        videoQueue.async { self.snapshotHandler = handler }
    }

    /// Upright, ~1024px tall JPEG of the current view for the AI.
    private func makeJPEG(_ buffer: CVPixelBuffer) -> (data: Data, width: Int, height: Int)? {
        let upright = CIImage(cvPixelBuffer: buffer).oriented(.right)
        let scale = 1024.0 / upright.extent.height
        let scaled = upright.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let data = ciContext.jpegRepresentation(
                of: scaled, colorSpace: cs,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7]) else {
            return nil
        }
        return (data, Int(scaled.extent.width.rounded()), Int(scaled.extent.height.rounded()))
    }

    // MARK: Capture

    func capture() {
        guard !isShooting else { return }
        isShooting = true
        resetShootTimer()

        var crop: CGRect? = nil
        if target != nil, let r = frameRect {
            let c = r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            if c.width > 0.2 && c.height > 0.2 { crop = c }
        }

        haptic(.heavy)
        flash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.flash = false }

        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .balanced

        let delegate = PhotoCaptureDelegate { [weak self] data in
            guard let self = self else { return }
            self.photoDelegate = nil
            guard let data = data, let image = UIImage(data: data) else {
                self.isShooting = false
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
                    self.isShooting = false
                    self.showToast("Saved to Photos")
                    if self.target != nil { self.clearTarget(resetZoom: true) }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            if self?.toast == text { self?.toast = nil }
        }
    }
}

extension CameraModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let handler = snapshotHandler,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        snapshotHandler = nil
        handler(buffer)
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
