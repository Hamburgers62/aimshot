import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraModel()
    @State private var dragRect: CGRect? = nil
    @State private var focusPoint: CGPoint? = nil
    @State private var showSettings = false
    @AppStorage("autoShoot") private var autoShoot = true
    @AppStorage("aspect") private var aspectRaw = ShotAspect.fourFive.rawValue
    @AppStorage("raw") private var rawOn = false
    @AppStorage("flash") private var flashRaw = FlashSetting.off.rawValue
    @Environment(\.scenePhase) private var scenePhase

    private let green = Color(red: 0.30, green: 0.85, blue: 0.40)
    private let yellow = Color(red: 1.0, green: 0.82, blue: 0.0)

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

                Text(camera.hint)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(hintColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity)

                if camera.ideas.count > 1 && camera.target != nil {
                    Button {
                        camera.nextIdea()
                    } label: {
                        Text("Idea \(camera.ideaIndex + 1) of \(camera.ideas.count)  ·  Next ›")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(yellow)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(yellow.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                }

                zoomPills
                    .padding(.top, 10)

                Spacer(minLength: 0)

                controls
                    .padding(.horizontal, 36)
                    .padding(.bottom, 20)
            }

            if let text = camera.toast {
                VStack {
                    Text(text)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.black)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.white))
                        .padding(.horizontal, 24)
                        .padding(.top, 60)
                    Spacer()
                }
                .transition(.opacity)
            }

            if camera.permissionDenied {
                permissionView
            }
        }
        .animation(.easeInOut(duration: 0.2), value: camera.toast)
        .animation(.easeInOut(duration: 0.25), value: camera.orientation)
        .statusBarHidden(true)
        .sheet(isPresented: $showSettings) { SettingsView() }
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

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                aspectRaw = aspect.next.rawValue
            } label: {
                Text(aspect.label(landscape: camera.orientation.isLandscape))
                    .font(.caption.weight(.bold))
                    .foregroundColor(.white)
                    .frame(minWidth: 34)
                    .padding(.vertical, 5)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.5), lineWidth: 1))
                    .rotationEffect(iconAngle)
            }
            .buttonStyle(.plain)

            if camera.rawSupported {
                Button {
                    rawOn.toggle()
                } label: {
                    Text("RAW")
                        .font(.caption.weight(.bold))
                        .foregroundColor(rawOn ? .black : .white.opacity(0.7))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(rawOn ? yellow : Color.white.opacity(0.12)))
                        .rotationEffect(iconAngle)
                }
                .buttonStyle(.plain)
            }

            Button {
                flashRaw = flashSetting.next.rawValue
            } label: {
                Image(systemName: flashSetting.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(flashSetting == .off ? .white : yellow)
                    .frame(width: 34, height: 34)
                    .rotationEffect(iconAngle)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                autoShoot.toggle()
            } label: {
                Text("AUTO")
                    .font(.caption.weight(.bold))
                    .foregroundColor(autoShoot ? .black : .white.opacity(0.7))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(autoShoot ? yellow : Color.white.opacity(0.12)))
                    .rotationEffect(iconAngle)
            }
            .buttonStyle(.plain)

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .rotationEffect(iconAngle)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .frame(height: 50)
    }

    private var hintColor: Color {
        switch camera.phase {
        case .ready: return green
        case .zooming: return yellow
        case .idle: return .white.opacity(0.6)
        default: return .white
        }
    }

    // MARK: Zoom buttons

    private var zoomPills: some View {
        let current = camera.displayZoom
        var stops = camera.zoomStops
        if !stops.contains(where: { abs($0 - current) < 0.05 }) {
            stops.append((current * 10).rounded() / 10)
            stops.sort()
        }
        return HStack(spacing: 12) {
            ForEach(stops, id: \.self) { s in
                let active = abs(s - current) < 0.06
                Button {
                    camera.selectZoom(s)
                } label: {
                    Text(zoomLabel(s, active: active))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(active ? yellow : .white.opacity(0.8))
                        .rotationEffect(iconAngle)
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(active ? yellow.opacity(0.18) : Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }
        }
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
        return s + (active ? "×" : "x")
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
            if let url = URL(string: "photos-redirect://") {
                UIApplication.shared.open(url)
            }
        } label: {
            Group {
                if let image = camera.lastPhoto {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.1)
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.3), lineWidth: 1))
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
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 80, height: 80)
                Circle()
                    .trim(from: 0, to: CGFloat(camera.shootProgress))
                    .stroke(green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 80, height: 80)
                Circle()
                    .fill(ready ? green : Color.white)
                    .frame(width: 66, height: 66)
            }
            .shadow(color: ready ? green.opacity(0.8) : .clear, radius: ready ? 14 : 0)
            .animation(.easeInOut(duration: 0.2), value: ready)
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
                    .fill(busy ? Color.white.opacity(0.12) : yellow.opacity(0.22))
                    .frame(width: 64, height: 64)
                if camera.phase == .scanning {
                    ProgressView().tint(yellow)
                } else {
                    Image(systemName: busy ? "xmark" : "sparkles")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(busy ? .white : yellow)
                        .rotationEffect(iconAngle)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var permissionView: some View {
        VStack(spacing: 16) {
            Text("Camera access is off")
                .font(.title3.weight(.semibold))
            Text("Turn it on in Settings so Aimshot can see what you're shooting.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.7))
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.white))
            .foregroundColor(.black)
        }
        .foregroundColor(.white)
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
        let accent = ready ? green : yellow
        let tilt = abs(camera.roll).truncatingRemainder(dividingBy: Double.pi / 2)
        let level = min(tilt, Double.pi / 2 - tilt) < 0.02

        ZStack {
            // Rule-of-thirds grid.
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
            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)

            // Level line: stays flat with the world as you tilt.
            Rectangle()
                .fill(level ? green : yellow)
                .frame(width: size.width * 0.4, height: 1.5)
                .rotationEffect(.radians(-camera.roll))
                .position(center)

            if let d = dragRect {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .frame(width: d.width, height: d.height)
                    .position(x: d.midX, y: d.midY)
            } else if let t = camera.target, let fr = camera.frameRect {
                let r = viewRect(fr, in: size)

                if camera.phase == .guiding {
                    Path { p in
                        p.move(to: center)
                        p.addLine(to: CGPoint(x: r.midX, y: r.midY))
                    }
                    .stroke(yellow.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                }

                RoundedRectangle(cornerRadius: 14)
                    .stroke(accent, lineWidth: 3)
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)

                subjectLabel(t.subject, ready: ready)
                    .rotationEffect(iconAngle)
                    .position(labelPosition(for: r, in: size))
            }

            // Crosshair: where you're aiming.
            ZStack {
                Rectangle().fill(ready ? green : Color.white.opacity(0.85)).frame(width: 18, height: 1.5)
                Rectangle().fill(ready ? green : Color.white.opacity(0.85)).frame(width: 1.5, height: 18)
            }
            .position(center)

            // Tap-to-focus square.
            if let fp = focusPoint {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(yellow, lineWidth: 1.5)
                    .frame(width: 64, height: 64)
                    .position(fp)
            }

            if camera.flash {
                Color.white.opacity(0.8)
            }
        }
        .allowsHitTesting(false)
    }

    private func subjectLabel(_ text: String, ready: Bool) -> some View {
        HStack(spacing: 6) {
            if ready {
                Circle().fill(green).frame(width: 7, height: 7)
            }
            Text(text)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundColor(ready ? green : yellow)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.55)))
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
