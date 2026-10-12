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
    @Published var ideas: [AimTarget] = []
    @Published var ideaIndex = 0
    /// Where the target is in the view right now (normalized Vision coords, origin bottom-left).
    @Published var frameRect: CGRect? = nil
    @Published var hint: String = "Tap ✦ to scan the scene"
    @Published var roll: Double = 0
    @Published var isLevel = false
    @Published var orientation: ShotOrientation = .portrait
    @Published var displayZoom: Double = 1
    @Published var zoomStops: [Double] = [1]
    @Published var shootProgress: Double = 0
    @Published var lastPhoto: UIImage? = nil
    @Published var toast: String? = nil
    @Published var permissionDenied = false
    @Published var isShooting = false
    @Published var flash = false
    @Published var rawSupported = false
    @Published var exposureBias: Double = 0
    @Published var exposureRange: ClosedRange<Double> = -2...2

    let session = AVCaptureSession()
    weak var previewLayer: AVCaptureVideoPreviewLayer?

    private let sessionQueue = DispatchQueue(label: "aimshot.session")
    private let videoQueue = DispatchQueue(label: "aimshot.video")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var configured = false
    private var rawFormat: OSType? = nil                 // sessionQueue
    private var photoDelegate: PhotoCaptureDelegate?     // sessionQueue
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
    private var smoothRoll: Double = 0
    private var scanToken = 0
    private var idleSteadySince: Date? = nil
    private var lastScanTime: Date = .distantPast
    private var lastScanForward: SIMD3<Double>? = nil

    // MARK: Snapshot (videoQueue only)
    private var snapshotHandler: ((CVPixelBuffer) -> Void)?

    // MARK: Lifecycle

    func start() {
        if lastPhoto == nil { lastPhoto = ShotLibrary.shared.latestThumbnail }
        if phase == .idle { setHint(idleHint) }
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
            if photoOutput.isAppleProRAWSupported {
                photoOutput.isAppleProRAWEnabled = true
            }
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        session.commitConfiguration()
        self.device = device

        let raws = photoOutput.availableRawPhotoPixelFormatTypes
        rawFormat = raws.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) ?? raws.first
        let hasRaw = rawFormat != nil
        DispatchQueue.main.async { self.rawSupported = hasRaw }

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

        let biasLow = max(Double(device.minExposureTargetBias), -3)
        let biasHigh = min(Double(device.maxExposureTargetBias), 3)
        let minZ = Double(device.minAvailableVideoZoomFactor)
        let maxZ = min(Double(device.maxAvailableVideoZoomFactor), uw * 15)

        // Start on the widest lens (sees the whole room) or 1x, per Settings.
        let startMain = UserDefaults.standard.string(forKey: "startLens") == "main"
        let startZ = startMain ? min(max(uw, minZ), maxZ) : minZ
        if (try? device.lockForConfiguration()) != nil {
            device.videoZoomFactor = CGFloat(startZ)
            device.unlockForConfiguration()
        }

        DispatchQueue.main.async {
            self.geometry = geo
            self.uwFactor = uw
            self.minZoom = minZ
            self.maxZoom = maxZ
            self.scanZoom = startZ
            self.zoomStops = stops
            if biasLow < biasHigh { self.exposureRange = biasLow...biasHigh }
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

    // MARK: Zoom + focus

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

    /// Tap to focus and expose at a point on the preview.
    func focus(atLayerPoint point: CGPoint) {
        guard let layer = previewLayer else { return }
        let p = layer.captureDevicePointConverted(fromLayerPoint: point)
        sessionQueue.async {
            guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            if d.isFocusPointOfInterestSupported && d.isFocusModeSupported(.continuousAutoFocus) {
                d.focusPointOfInterest = p
                d.focusMode = .continuousAutoFocus
            }
            if d.isExposurePointOfInterestSupported && d.isExposureModeSupported(.continuousAutoExposure) {
                d.exposurePointOfInterest = p
                d.exposureMode = .continuousAutoExposure
            }
            d.unlockForConfiguration()
        }
    }

    /// Back to focusing and exposing on the middle of the view.
    private func resetFocus() {
        sessionQueue.async {
            guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            let centre = CGPoint(x: 0.5, y: 0.5)
            if d.isFocusPointOfInterestSupported && d.isFocusModeSupported(.continuousAutoFocus) {
                d.focusPointOfInterest = centre
                d.focusMode = .continuousAutoFocus
            }
            if d.isExposurePointOfInterestSupported && d.isExposureModeSupported(.continuousAutoExposure) {
                d.exposurePointOfInterest = centre
                d.exposureMode = .continuousAutoExposure
            }
            d.unlockForConfiguration()
        }
    }

    /// Brighter / darker, in EV stops.
    func setExposure(_ value: Double) {
        let v = min(max(value, exposureRange.lowerBound), exposureRange.upperBound)
        exposureBias = v
        sessionQueue.async {
            guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            d.setExposureTargetBias(Float(v), completionHandler: nil)
            d.unlockForConfiguration()
        }
    }

    // MARK: Auto-scan

    private var autoScanOn: Bool { UserDefaults.standard.bool(forKey: "autoScan") }

    func refreshIdleHint() {
        if phase == .idle { setHint(idleHint) }
    }

    var idleHint: String {
        autoScanOn ? "Hold still to auto-scan, or tap ✦" : "Tap ✦ to scan the scene"
    }

    /// Scans by itself when you hold still on a new view.
    private func checkAutoScan(spin: Double) {
        guard autoScanOn, phase == .idle, !isShooting else {
            idleSteadySince = nil
            return
        }
        if spin > 0.2 {
            idleSteadySince = nil
            return
        }
        if idleSteadySince == nil { idleSteadySince = Date() }
        guard let since = idleSteadySince,
              Date().timeIntervalSince(since) > 1.2,
              Date().timeIntervalSince(lastScanTime) > 6 else { return }

        let forward = AimMath.toWorld(SIMD3(0, 0, -1), attitude)
        if let last = lastScanForward, Date().timeIntervalSince(lastScanTime) < 45 {
            let angle = acos(min(max(simd_dot(forward, last), -1), 1))
            guard angle > 0.3 else { return }   // same view as last time
        }
        idleSteadySince = nil
        scan()
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

        let gx = m.gravity.x
        let gy = m.gravity.y
        // Smoothed tilt for the level line (raw sensor values jitter a lot).
        var diff = atan2(gx, -gy) - smoothRoll
        if diff > .pi { diff -= 2 * .pi } else if diff < -.pi { diff += 2 * .pi }
        smoothRoll += diff * 0.12
        if abs(smoothRoll - roll) > 0.004 { roll = smoothRoll }
        let quarter = Double.pi / 2
        let r = abs(smoothRoll).truncatingRemainder(dividingBy: quarter)
        let tilt = min(r, quarter - r)
        let nowLevel = isLevel ? tilt < 0.026 : tilt < 0.012   // in at ~0.7°, out at ~1.5°
        if nowLevel != isLevel {
            isLevel = nowLevel
            if nowLevel { haptic(.soft) }
        }

        // Portrait or sideways? (ignored while the phone lies flat)
        if abs(m.gravity.z) < 0.8 {
            var o = orientation
            if abs(gx) > abs(gy) + 0.3 {
                o = gx > 0 ? .landscapeTopRight : .landscapeTopLeft
            } else if abs(gy) > abs(gx) + 0.3 {
                o = .portrait
            }
            if o != orientation { orientation = o }
        }

        let rr = m.rotationRate
        let spin = sqrt(rr.x * rr.x + rr.y * rr.y + rr.z * rr.z)
        updateGuide(spin: spin)
        checkAutoScan(spin: spin)
    }

    // MARK: Guiding

    private func updateGuide(spin: Double) {
        guard let t = target, phase != .idle, phase != .scanning else { return }

        guard let rect = AimMath.project(t, r: attitude, zoom: zoomFactor, geo: geometry,
                                         landscapeNow: orientation.isLandscape),
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
                let fill = zoomFactor * 0.92 / Double(max(rect.width, rect.height))
                let z = min(max(fill, minZoom), maxZoom)
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
            setHint(directionHint(dx: dx, dy: dy, tolX: tolX, tolY: tolY, subject: t.subject))
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

    /// Screen-space offsets turned into words that match how the phone is held.
    private func directionHint(dx: Double, dy: Double, tolX: Double, tolY: Double, subject: String) -> String {
        // In device terms: +x = screen right, +y = screen up.
        var right = 0.0
        var up = 0.0
        switch orientation {
        case .portrait:
            right = dx; up = dy
        case .landscapeTopRight:   // screen up points to your right
            right = dy; up = -dx
        case .landscapeTopLeft:    // screen up points to your left
            right = -dy; up = dx
        }
        let tolRight = orientation.isLandscape ? tolY : tolX
        let tolUp = orientation.isLandscape ? tolX : tolY
        var parts: [String] = []
        if abs(right) > tolRight { parts.append(right > 0 ? "right" : "left") }
        if abs(up) > tolUp { parts.append(up > 0 ? "up" : "down") }
        if parts.isEmpty { return "Hold it there…" }
        return "Aim \(parts.joined(separator: " and ")) at the \(subject)"
    }

    private func resetShootTimer() {
        steadySince = nil
        if shootProgress != 0 { shootProgress = 0 }
    }

    private func offscreenHint(_ t: AimTarget) -> String {
        let v = AimMath.toDevice(t.worldDir, attitude)
        if v.z > 0 { return "Turn around to find the \(t.subject)" }
        let tolX = 0.5 * Double(max(abs(v.x), abs(v.y)))
        return directionHint(dx: v.x, dy: v.y, tolX: tolX, tolY: tolX, subject: t.subject)
            .replacingOccurrences(of: "Aim ", with: "Turn ")
    }

    private func setHint(_ s: String) {
        if hint != s { hint = s }
    }

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard UserDefaults.standard.object(forKey: "haptics") as? Bool ?? true else { return }
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
        lastScanTime = Date()
        lastScanForward = AimMath.toWorld(SIMD3(0, 0, -1), attitude)

        let r0 = attitude
        let z0 = zoomFactor
        let geo = geometry
        let orient = orientation
        scanZoom = zoomFactor
        let aspect = ShotAspect.current
        let wOverH = aspect.wOverH(landscape: orient.isLandscape)
        let key = AIConfig.key
        let model = AIConfig.modelID
        let style = ShotStyle.current
        let count = AIConfig.ideasPerScan

        requestSnapshot { [weak self] buffer in
            guard let self = self else { return }

            if key.isEmpty {
                let box = Composer.bestFrame(in: buffer, orientation: orient.bufferOrientation,
                                             wOverH: CGFloat(wOverH))
                let idea = ShotIdea(subject: "interesting spot",
                                    why: "basic guess, add an API key for smart picks",
                                    box: box)
                DispatchQueue.main.async {
                    guard token == self.scanToken else { return }
                    self.setIdeas([idea], r: r0, zoom: z0, geo: geo, orient: orient)
                }
                return
            }

            guard let snap = self.makeJPEG(buffer, orientation: orient.bufferOrientation) else {
                DispatchQueue.main.async { self.scanFailed("Couldn't read the camera", token: token) }
                return
            }

            Task {
                do {
                    let shots = try await AIScout.findShots(
                        jpeg: snap.data, width: snap.width, height: snap.height,
                        key: key, model: model,
                        aspectLabel: aspect.label(landscape: orient.isLandscape),
                        landscape: orient.isLandscape, wOverH: wOverH,
                        style: style, count: count)
                    await MainActor.run {
                        guard token == self.scanToken else { return }
                        self.setIdeas(shots, r: r0, zoom: z0, geo: geo, orient: orient)
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
        setHint(idleHint)
        showToast(message)
        lastScanTime = Date().addingTimeInterval(54)   // pause auto-scan for a minute after an error
    }

    /// Your own frame: the user drew a box (normalized Vision coords in the preview).
    func setCustomFrame(_ rect: CGRect) {
        clearTarget(resetZoom: false)
        scanZoom = zoomFactor
        let t = AimMath.target(from: rect, r: attitude, zoom: zoomFactor, geo: geometry,
                               landscape: orientation.isLandscape,
                               subject: "your frame", why: "your shot, hold steady")
        ideas = [t]
        ideaIndex = 0
        activate(t)
    }

    private func setIdeas(_ shots: [ShotIdea], r: simd_double3x3, zoom: Double, geo: CameraGeometry,
                          orient: ShotOrientation) {
        ideas = shots.map { shot in
            let portraitBox = OrientMath.toPortrait(shot.box, from: orient)
            return AimMath.target(from: OrientMath.flipY(portraitBox), r: r, zoom: zoom, geo: geo,
                                  landscape: orient.isLandscape, subject: shot.subject, why: shot.why)
        }
        ideaIndex = 0
        if let first = ideas.first { activate(first) }
    }

    /// Show the next AI idea (if it found more than one).
    func nextIdea() {
        guard ideas.count > 1 else { return }
        ideaIndex = (ideaIndex + 1) % ideas.count
        if zoomFactor > scanZoom * 1.05 { rampZoom(to: scanZoom, rate: 6) }
        activate(ideas[ideaIndex])
    }

    private func activate(_ t: AimTarget) {
        target = t
        targetZoom = nil
        resetShootTimer()
        phase = .guiding
        resetFocus()
        haptic(.light)
        updateGuide(spin: 1)
    }

    func clearTarget(resetZoom: Bool = true) {
        scanToken += 1
        target = nil
        ideas = []
        ideaIndex = 0
        frameRect = nil
        targetZoom = nil
        resetShootTimer()
        phase = .idle
        setHint(idleHint)
        if resetZoom { rampZoom(to: scanZoom, rate: 6) }
    }

    private func requestSnapshot(_ handler: @escaping (CVPixelBuffer) -> Void) {
        videoQueue.async { self.snapshotHandler = handler }
    }

    /// Upright JPEG of the current view for the AI, long side 1024px.
    private func makeJPEG(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation)
        -> (data: Data, width: Int, height: Int)? {
        let upright = CIImage(cvPixelBuffer: buffer).oriented(orientation)
        let scale = 1024.0 / max(upright.extent.width, upright.extent.height)
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

        let orient = orientation
        var crop: CGRect? = nil
        if target != nil, let r = frameRect {
            let c = r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            if c.width > 0.15 && c.height > 0.15 {
                crop = OrientMath.fromPortrait(OrientMath.flipY(c), to: orient)
            }
        }
        let subject = target?.subject ?? "photo"
        let why = target?.why ?? ""
        let wantRaw = rawSupported && UserDefaults.standard.bool(forKey: "raw")
        let flashMode = FlashSetting.current.mode

        haptic(.heavy)
        flash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.flash = false }

        sessionQueue.async {
            let settings = self.makeSettings(raw: wantRaw, flash: flashMode)
            if let conn = self.photoOutput.connection(with: .video) {
                if #available(iOS 17.0, *) {
                    if conn.isVideoRotationAngleSupported(orient.rotationAngle) {
                        conn.videoRotationAngle = orient.rotationAngle
                    }
                } else {
                    if conn.isVideoOrientationSupported { conn.videoOrientation = orient.legacyVideoOrientation }
                }
            }
            let delegate = PhotoCaptureDelegate { [weak self] result in
                self?.finishCapture(result, crop: crop, subject: subject, why: why)
            }
            self.photoDelegate = delegate
            self.photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    /// Runs on sessionQueue.
    private func makeSettings(raw: Bool, flash: AVCaptureDevice.FlashMode) -> AVCapturePhotoSettings {
        let codec: AVVideoCodecType = photoOutput.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
        let processed: [String: Any] = [AVVideoCodecKey: codec]
        let settings: AVCapturePhotoSettings
        if raw, let fmt = rawFormat {
            settings = AVCapturePhotoSettings(rawPixelFormatType: fmt, processedFormat: processed)
        } else {
            settings = AVCapturePhotoSettings(format: processed)
            settings.photoQualityPrioritization = .balanced
        }
        if photoOutput.supportedFlashModes.contains(flash) {
            settings.flashMode = flash
        }
        return settings
    }

    /// Runs on main. Frees the shutter straight away, then develops and saves in the background:
    /// to Photos (with your default look or an AI-picked edit) and to the shot history.
    private func finishCapture(_ result: CaptureResult, crop: CGRect?, subject: String, why: String) {
        sessionQueue.async { self.photoDelegate = nil }
        isShooting = false
        if target != nil { clearTarget(resetZoom: true) }

        guard let data = result.processed, let image = UIImage(data: data) else {
            showToast("Couldn't take the photo")
            return
        }
        let metadata = result.metadata
        let raw = result.raw
        let defaults = EditSettings.forNewShots
        let aiEdit = UserDefaults.standard.bool(forKey: "aiEditNew")
        let key = AIConfig.key
        let model = AIConfig.modelID
        if aiEdit && !key.isEmpty { showToast("Developing with AI…") }

        Task.detached(priority: .userInitiated) {
            let upright = image.normalizedUp()
            let final = crop.map { upright.cropped(toTopLeftRect: $0) } ?? upright
            let specs = PhotoSpecs.describe(metadata)
            let clean = final.cgImage.flatMap { PhotoSaver.encode($0, metadata: metadata) } ?? data

            var edits = defaults
            var note: String? = nil
            if aiEdit && !key.isEmpty,
               let small = final.preparingThumbnail(of: CGSize(width: 1024, height: 1024)),
               let jpeg = small.jpegData(compressionQuality: 0.7),
               let suggestion = try? await AIScout.suggestEdit(jpeg: jpeg, key: key, model: model, subject: subject) {
                edits = suggestion.settings
                edits.frame = defaults.frame
                edits.dateStamp = defaults.dateStamp
                note = suggestion.note
            }

            var toPhotos = clean
            var thumbSource = final
            if !edits.isPlain, let cg = final.cgImage,
               let styled = FilmLab.renderFinal(cg, edits, date: Date(), specs: specs),
               let styledData = PhotoSaver.encode(styled, metadata: metadata) {
                toPhotos = styledData
                thumbSource = UIImage(cgImage: styled)
            }
            let thumb = thumbSource.preparingThumbnail(of: CGSize(width: 300, height: 300)) ?? thumbSource

            ShotLibrary.shared.store(photo: clean, thumb: thumb, subject: subject, why: why,
                                     specs: specs, edits: edits, editNote: note)

            let lookName = FilmLab.look(edits.look).name
            let aiEdited = note != nil
            PhotoSaver.save(photo: toPhotos, raw: raw) { ok in
                self.lastPhoto = thumb
                if !ok {
                    self.showToast("Allow Photos access in Settings to save")
                } else if aiEdited {
                    self.showToast("Saved with \(lookName)")
                } else {
                    self.showToast(raw != nil ? "Saved photo + RAW" : "Saved to Photos")
                }
            }
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

struct CaptureResult {
    var processed: Data?
    var metadata: [String: Any] = [:]
    var raw: Data?
}

/// Collects the processed photo (and the RAW one, if asked for), then reports once.
final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private var result = CaptureResult()
    private let completion: (CaptureResult) -> Void

    init(completion: @escaping (CaptureResult) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        if photo.isRawPhoto {
            result.raw = data
        } else {
            result.processed = data
            result.metadata = photo.metadata
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        let r = result
        DispatchQueue.main.async { self.completion(r) }
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

    /// Crops to a normalized rect (origin top-left). Expects an upright image.
    func cropped(toTopLeftRect r: CGRect) -> UIImage {
        guard let cg = cgImage else { return self }
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        let rect = CGRect(x: r.minX * w, y: r.minY * h, width: r.width * w, height: r.height * h)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !rect.isEmpty, let cropped = cg.cropping(to: rect) else { return self }
        return UIImage(cgImage: cropped, scale: 1, orientation: .up)
    }
}
