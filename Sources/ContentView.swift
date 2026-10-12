import SwiftUI

/// Viewfinder-style corner brackets for the target frame.
struct CornerFrame: Shape {
    var length: CGFloat

    func path(in r: CGRect) -> Path {
        var p = Path()
        let l = min(length, r.width / 3, r.height / 3)
        p.move(to: CGPoint(x: r.minX, y: r.minY + l))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + l, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - l, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + l))
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - l))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - l, y: r.maxY))
        p.move(to: CGPoint(x: r.minX + l, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - l))
        return p
    }
}

struct ContentView: View {
    @StateObject private var camera = CameraModel()
    @State private var dragRect: CGRect? = nil
    @State private var focusPoint: CGPoint? = nil
    @State private var showSettings = false
    @State private var showLibrary = false
    @State private var showExposure = false
    @AppStorage("autoShoot") private var autoShoot = true
    @AppStorage("aspect") private var aspectRaw = ShotAspect.fourFive.rawValue
    @AppStorage("raw") private var rawOn = false
    @AppStorage("flash") private var flashRaw = FlashSetting.off.rawValue
    @AppStorage("showGrid") private var showGrid = true
    @AppStorage("showLevel") private var showLevel = true
    @Environment(\.scenePhase) private var scenePhase

    private var aspect: ShotAspect { ShotAspect(rawValue: aspectRaw) ?? .fourFive }
    private var flashSetting: FlashSetting { FlashSetting(rawValue: flashRaw) ?? .off }
    private var iconAngle: Angle { .degrees(camera.orientation.iconDegrees) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                GeometryReader { geo in
                    ZStack {
                        CameraPreview(session: camera.session,
                                      onLayer: { camera.previewLayer = $0 },
                                      onHardwareShutter: { camera.capture() })
                        frameOverlay(size: geo.size)
                    }
                    .contentShape(Rectangle())
                    .gesture(drawGesture(size: geo.size))
                    .simultaneousGesture(
                        SpatialTapGesture().onEnded { value in
                            camera.focus(atLayerPoint: value.location)
                            showFocus(at: value.location)
                        }
                    )
                    .clipped()
                }
                .aspectRatio(3.0 / 4.0, contentMode: .fit)

                hintLine
                    .padding(.top, 14)
                    .frame(height: 50, alignment: .top)

                if camera.ideas.count > 1 && camera.target != nil {
                    Button {
                        camera.nextIdea()
                    } label: {
                        Text("Next idea (\(camera.ideaIndex + 1) of \(camera.ideas.count))")
                            .font(Theme.ui(13, .semibold))
                            .foregroundColor(Theme.amber)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .overlay(Capsule().stroke(Theme.amber.opacity(0.5), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }

                Group {
                    if showExposure {
                        exposureRow
                    } else {
                        zoomTray
                    }
                }
                .padding(.top, 10)

                Spacer(minLength: 0)

                controls
                    .padding(.horizontal, 32)
                    .padding(.bottom, 18)
            }

            if let text = camera.toast {
                VStack {
                    Text(text)
                        .font(Theme.ui(14, .semibold))
                        .foregroundColor(.black)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Theme.paper))
                        .padding(.horizontal, 24)
                        .padding(.top, 64)
                    Spacer()
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }

            if camera.permissionDenied {
                permissionView
            }
        }
        .tint(Theme.amber)
        .animation(.easeInOut(duration: 0.2), value: camera.toast)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: camera.orientation)
        .statusBarHidden(true)
        .sheet(isPresented: $showSettings, onDismiss: { camera.refreshIdleHint() }) { SettingsView() }
        .sheet(isPresented: $showLibrary) { LibraryView() }
        .onAppear { camera.start() }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                camera.start()
            } else if phase == .background {
                camera.stop()
            }
        }
    }

    private func showFocus(at point: CGPoint) {
        focusPoint = point
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if focusPoint == point { focusPoint = nil }
        }
    }

    // MARK: Top bar

    private func trayButton<Label: View>(_ action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label()
                .frame(width: 38, height: 34)
                .contentShape(Rectangle())
                .rotationEffect(iconAngle)
        }
        .buttonStyle(.plain)
    }

    private var topBar: some View {
        HStack {
            HStack(spacing: 2) {
                trayButton({ aspectRaw = aspect.next.rawValue }) {
                    Text(aspect.label(landscape: camera.orientation.isLandscape))
                        .font(Theme.ui(13, .semibold).monospacedDigit())
                        .foregroundColor(Theme.paper)
                }
                if camera.rawSupported {
                    trayButton({ rawOn.toggle() }) {
                        Text("RAW")
                            .font(Theme.ui(12, .bold))
                            .foregroundColor(rawOn ? Theme.amber : Theme.muted)
                    }
                }
                trayButton({ flashRaw = flashSetting.next.rawValue }) {
                    Image(systemName: flashSetting.icon)
                        .font(Theme.ui(15, .semibold))
                        .foregroundColor(flashSetting == .off ? Theme.muted : Theme.amber)
                }
                trayButton({ showExposure.toggle() }) {
                    Image(systemName: "plusminus.circle")
                        .font(Theme.ui(15, .semibold))
                        .foregroundColor(showExposure || camera.exposureBias != 0 ? Theme.amber : Theme.muted)
                }
            }
            .padding(.horizontal, 4)
            .background(Capsule().fill(Theme.well))

            Spacer()

            HStack(spacing: 2) {
                trayButton({ autoShoot.toggle() }) {
                    Text("Auto")
                        .font(Theme.ui(13, .semibold))
                        .foregroundColor(autoShoot ? Theme.amber : Theme.muted)
                }
                trayButton({ showSettings = true }) {
                    Image(systemName: "gearshape")
                        .font(Theme.ui(15, .semibold))
                        .foregroundColor(Theme.paper)
                }
            }
            .padding(.horizontal, 4)
            .background(Capsule().fill(Theme.well))
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    // MARK: Hint line (the AI speaks in serif)

    @ViewBuilder
    private var hintLine: some View {
        switch camera.phase {
        case .ready:
            Text(camera.hint)
                .font(Theme.note(19))
                .foregroundColor(Theme.go)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 28)
        case .zooming:
            Text(camera.hint)
                .font(Theme.ui(15))
                .foregroundColor(Theme.amber)
        case .idle:
            Text(camera.hint)
                .font(Theme.ui(15))
                .foregroundColor(Theme.muted)
        default:
            Text(camera.hint)
                .font(Theme.ui(15))
                .foregroundColor(Theme.paper)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 28)
        }
    }

    // MARK: Exposure

    private var exposureRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "sun.max")
                .foregroundColor(Theme.amber)
                .rotationEffect(iconAngle)
            Slider(value: Binding(get: { camera.exposureBias },
                                  set: { camera.setExposure($0) }),
                   in: camera.exposureRange)
            Button {
                camera.setExposure(0)
            } label: {
                Text(String(format: "%+.1f", camera.exposureBias))
                    .font(Theme.ui(13, .semibold).monospacedDigit())
                    .foregroundColor(Theme.paper)
                    .frame(width: 48, height: 34)
                    .background(Capsule().fill(Theme.well))
                    .rotationEffect(iconAngle)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 32)
        .frame(height: 44)
    }

    // MARK: Zoom

    private var zoomTray: some View {
        let current = camera.displayZoom
        var stops = camera.zoomStops
        if !stops.contains(where: { abs($0 - current) < 0.05 }) {
            stops.append((current * 10).rounded() / 10)
            stops.sort()
        }
        return HStack(spacing: 4) {
            ForEach(stops, id: \.self) { s in
                let active = abs(s - current) < 0.06
                Button {
                    camera.selectZoom(s)
                } label: {
                    Text(zoomLabel(s, active: active))
                        .font(Theme.ui(active ? 13 : 12, .semibold).monospacedDigit())
                        .foregroundColor(active ? Theme.amber : Theme.paper.opacity(0.8))
                        .rotationEffect(iconAngle)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(active ? Color.black.opacity(0.6) : Color.clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(Theme.well))
        .frame(height: 48)
    }

    private func zoomLabel(_ z: Double, active: Bool) -> String {
        let s: String
        if z < 0.95 {
            s = String(format: ".%.0f", z * 10)
        } else if abs(z - z.rounded()) < 0.05 {
            s = String(format: "%.0f", z)
        } else {
            s = String(format: "%.1f", z)
        }
        return active ? s + "×" : s
    }

    // MARK: Bottom controls

    private var controls: some View {
        HStack {
            thumbnail
            Spacer()
            shutter
            Spacer()
            scanButton
        }
    }

    private var thumbnail: some View {
        Button {
            showLibrary = true
        } label: {
            Group {
                if let image = camera.lastPhoto {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Theme.well
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.paper.opacity(0.25), lineWidth: 1))
            .rotationEffect(iconAngle)
        }
        .buttonStyle(.plain)
    }

    private var shutter: some View {
        let ready = camera.phase == .ready
        return Button {
            camera.capture()
        } label: {
            ZStack {
                Circle()
                    .stroke(Theme.paper, lineWidth: 3)
                    .frame(width: 78, height: 78)
                Circle()
                    .trim(from: 0, to: CGFloat(camera.shootProgress))
                    .stroke(Theme.go, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 78, height: 78)
                Circle()
                    .fill(ready ? Theme.go : Theme.paper)
                    .frame(width: 64, height: 64)
                    .scaleEffect(camera.isShooting ? 0.9 : 1)
            }
            .animation(.easeOut(duration: 0.15), value: ready)
            .animation(.easeOut(duration: 0.1), value: camera.isShooting)
        }
        .buttonStyle(.plain)
        .disabled(camera.isShooting)
    }

    private var scanButton: some View {
        let busy = camera.target != nil || camera.phase == .scanning
        return Button {
            if busy { camera.clearTarget() } else { camera.scan() }
        } label: {
            ZStack {
                Circle()
                    .stroke(busy ? Theme.paper.opacity(0.25) : Theme.amber, lineWidth: 1.5)
                    .frame(width: 56, height: 56)
                if camera.phase == .scanning {
                    ProgressView().tint(Theme.amber)
                } else {
                    Image(systemName: busy ? "xmark" : "sparkles")
                        .font(Theme.ui(21, .semibold))
                        .foregroundColor(busy ? Theme.paper : Theme.amber)
                        .rotationEffect(iconAngle)
                }
            }
            .frame(width: 64, height: 64)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var permissionView: some View {
        VStack(spacing: 16) {
            Text("Camera access is off")
                .font(Theme.title(22))
            Text("Turn it on in Settings so Aimshot can see what you're shooting.")
                .font(Theme.ui(15))
                .multilineTextAlignment(.center)
                .foregroundColor(Theme.muted)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(Theme.ui(15, .semibold))
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Capsule().fill(Theme.amber))
            .foregroundColor(.black)
        }
        .foregroundColor(Theme.paper)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    // MARK: Overlay on the camera view

    /// Vision rect (normalized, origin bottom-left) -> view rect (points, origin top-left).
    private func viewRect(_ r: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: r.minX * size.width,
               y: (1 - r.maxY) * size.height,
               width: r.width * size.width,
               height: r.height * size.height)
    }

    /// Where the subject name goes: just "below" the frame as you're holding the phone.
    private func labelPosition(for r: CGRect, in size: CGSize) -> CGPoint {
        switch camera.orientation {
        case .portrait:
            return CGPoint(x: min(max(r.midX, 90), size.width - 90),
                           y: min(r.maxY + 24, size.height - 20))
        case .landscapeTopRight:
            return CGPoint(x: min(r.maxX + 24, size.width - 20),
                           y: min(max(r.midY, 90), size.height - 90))
        case .landscapeTopLeft:
            return CGPoint(x: max(r.minX - 24, 20),
                           y: min(max(r.midY, 90), size.height - 90))
        }
    }

    @ViewBuilder
    private func frameOverlay(size: CGSize) -> some View {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let ready = camera.phase == .ready
        let accent = ready ? Theme.go : Theme.amber
        let quarter = Double.pi / 2
        let r0 = abs(camera.roll).truncatingRemainder(dividingBy: quarter)
        let tilt = min(r0, quarter - r0)

        ZStack {
            if showGrid {
                Path { p in
                    for i in 1...2 {
                        let x = size.width * CGFloat(i) / 3
                        let y = size.height * CGFloat(i) / 3
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x, y: size.height))
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: size.width, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.22), lineWidth: 0.5)
            }

            // Level line: only shows when you're close to level, turns green when you are.
            if showLevel && tilt < 0.17 {
                HStack(spacing: 0) {
                    Rectangle().frame(width: size.width * 0.12, height: 1)
                    Spacer().frame(width: 34)
                    Rectangle().frame(width: size.width * 0.12, height: 1)
                }
                .foregroundColor(camera.isLevel ? Theme.go : Theme.paper.opacity(0.7))
                .rotationEffect(.radians(-camera.roll))
                .position(center)
                .opacity(camera.phase == .ready ? 0 : 1)
            }

            if let d = dragRect {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Theme.paper, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .frame(width: d.width, height: d.height)
                    .position(x: d.midX, y: d.midY)
            } else if let t = camera.target, let fr = camera.frameRect {
                let r = viewRect(fr, in: size)

                if camera.phase == .guiding {
                    Path { p in
                        p.move(to: center)
                        p.addLine(to: CGPoint(x: r.midX, y: r.midY))
                    }
                    .stroke(Theme.amber.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [3, 5]))
                    Circle()
                        .fill(Theme.amber)
                        .frame(width: 8, height: 8)
                        .position(x: r.midX, y: r.midY)
                }

                Rectangle()
                    .stroke(accent.opacity(0.35), lineWidth: 1)
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                CornerFrame(length: 26)
                    .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)

                subjectLabel(t.subject, score: t.score, ready: ready)
                    .rotationEffect(iconAngle)
                    .position(labelPosition(for: r, in: size))
            }

            // Crosshair: where you're aiming.
            ZStack {
                Rectangle().frame(width: 16, height: 1.5)
                Rectangle().frame(width: 1.5, height: 16)
            }
            .foregroundColor(ready ? Theme.go : Theme.paper.opacity(0.9))
            .position(center)

            if let fp = focusPoint {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Theme.amber, lineWidth: 1.2)
                    .frame(width: 60, height: 60)
                    .position(fp)
            }

            if camera.flash {
                Color.white.opacity(0.75)
            }
        }
        .allowsHitTesting(false)
    }

    private func subjectLabel(_ text: String, score: Int, ready: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(text)
                .font(Theme.note(16))
            if score > 0 {
                Text("\(score)/10")
                    .font(Theme.ui(11, .semibold).monospacedDigit())
                    .opacity(0.75)
            }
        }
            .lineLimit(1)
            .fixedSize()
            .foregroundColor(ready ? Theme.go : Theme.amber)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.6)))
    }

    // MARK: Draw your own frame

    private func drawGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                let a = value.startLocation
                let b = value.location
                dragRect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                  width: abs(a.x - b.x), height: abs(a.y - b.y))
            }
            .onEnded { _ in
                guard let r = dragRect else { return }
                dragRect = nil
                let c = r.intersection(CGRect(origin: .zero, size: size))
                guard c.width > 40, c.height > 40 else { return }
                let vision = CGRect(x: c.minX / size.width,
                                    y: 1 - c.maxY / size.height,
                                    width: c.width / size.width,
                                    height: c.height / size.height)
                camera.setCustomFrame(vision)
            }
    }
}
