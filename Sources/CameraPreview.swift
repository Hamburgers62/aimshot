import SwiftUI
import AVFoundation
import AVKit

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

/// Shows the live camera feed. Uses .resizeAspect inside a 3:4 box,
/// so the whole camera image is visible and overlay maths stays simple.
/// Also lets the volume buttons work as a shutter (iOS 17.2+).
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var onLayer: (AVCaptureVideoPreviewLayer) -> Void
    var onHardwareShutter: () -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        onLayer(view.previewLayer)

        if #available(iOS 17.2, *) {
            let shutter = onHardwareShutter
            let interaction = AVCaptureEventInteraction { event in
                if event.phase == .began { shutter() }
            }
            view.addInteraction(interaction)
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
