import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraModel()
    @State private var dragRect: CGRect? = nil
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                GeometryReader { geo in
                    ZStack {
                        CameraPreview(session: camera.session)
                        overlay(size: geo.size)
                    }
                    .contentShape(Rectangle())
                    .gesture(drawGesture(size: geo.size))
                }
                .aspectRatio(3.0 / 4.0, contentMode: .fit)

                Text(hintText)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(camera.hint == .aligned ? .yellow : .white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)

                Spacer(minLength: 0)

                controls
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
            }

            if let text = camera.toast {
                VStack {
                    Text(text)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.white))
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
        .statusBarHidden(true)
        .onAppear { camera.start() }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                camera.start()
            } else if phase == .background {
                camera.stop()
            }
        }
    }

    // MARK: Pieces

    private var topBar: some View {
        HStack {
            Text("Aimshot")
                .font(.headline)
                .foregroundColor(.white)
            Spacer()
            Text("v0.1")
                .font(.caption)
                .foregroundColor(.white.opacity(0.4))
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
    }

    private var hintText: String {
        switch camera.hint {
        case .none:
            return camera.isScanning
                ? "Finding the shot…"
                : "Tap Scan, or drag on the screen to draw your own frame"
        case .lost:
            return "Lost the frame. Scan again."
        case .aligned:
            return "Lined up. Take the shot!"
        case .move(let dx, let dy):
            var parts: [String] = []
            if abs(dx) > 0.035 { parts.append(dx > 0 ? "right" : "left") }
            if abs(dy) > 0.035 { parts.append(dy > 0 ? "up" : "down") }
            if parts.isEmpty { return "Almost…" }
            return "Aim " + parts.joined(separator: " and ") + " until the dot is in the ring"
        }
    }

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
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var shutter: some View {
        let aligned = camera.hint == .aligned
        return Button {
            camera.capture()
        } label: {
            ZStack {
                Circle()
                    .stroke(aligned ? Color.yellow : Color.white, lineWidth: 4)
                    .frame(width: 78, height: 78)
                Circle()
                    .fill(aligned ? Color.yellow : Color.white)
                    .frame(width: 64, height: 64)
            }
            .shadow(color: aligned ? Color.yellow.opacity(0.9) : Color.clear, radius: aligned ? 16 : 0)
            .scaleEffect(aligned ? 1.06 : 1.0)
            .animation(.easeInOut(duration: 0.25), value: aligned)
        }
        .buttonStyle(.plain)
    }

    private var scanButton: some View {
        let hasFrame = camera.targetRect != nil
        return Button {
            if hasFrame { camera.clearFrame() } else { camera.scan() }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: hasFrame ? "xmark" : "sparkles")
                    .font(.system(size: 22, weight: .semibold))
                Text(hasFrame ? "Clear" : "Scan")
                    .font(.caption.weight(.semibold))
            }
            .foregroundColor(.white)
            .frame(width: 60, height: 60)
        }
        .buttonStyle(.plain)
        .disabled(camera.isScanning)
        .opacity(camera.isScanning ? 0.4 : 1)
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

    // MARK: Overlay

    /// Vision rect (normalized, origin bottom-left) -> view rect (points, origin top-left).
    private func viewRect(_ r: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: r.minX * size.width,
               y: (1 - r.maxY) * size.height,
               width: r.width * size.width,
               height: r.height * size.height)
    }

    @ViewBuilder
    private func overlay(size: CGSize) -> some View {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let aligned = camera.hint == .aligned
        let accent: Color = aligned ? .yellow : .white

        ZStack {
            if let d = dragRect {
                Rectangle()
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .frame(width: d.width, height: d.height)
                    .position(x: d.midX, y: d.midY)
            } else if let t = camera.targetRect {
                let r = viewRect(t, in: size)

                // Dim everything outside the frame.
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: size))
                    p.addRect(r)
                }
                .fill(Color.black.opacity(0.4), style: FillStyle(eoFill: true))

                Rectangle()
                    .stroke(accent, lineWidth: aligned ? 3 : 2)
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)

                if !aligned {
                    Path { p in
                        p.move(to: center)
                        p.addLine(to: CGPoint(x: r.midX, y: r.midY))
                    }
                    .stroke(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                }

                // The dot: where the frame's centre is right now.
                Circle()
                    .fill(accent)
                    .frame(width: 12, height: 12)
                    .position(x: r.midX, y: r.midY)
            }

            // The ring: where you're aiming.
            Circle()
                .stroke(aligned ? Color.yellow : Color.white.opacity(0.8), lineWidth: 2)
                .frame(width: 44, height: 44)
                .position(center)
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.12), value: camera.targetRect)
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
