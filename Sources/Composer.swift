import Vision
import CoreGraphics
import CoreVideo

/// Picks a "best shot" frame from a camera image.
/// All rects are normalized (0...1) in Vision coordinates: origin bottom-left, image upright.
enum Composer {
    /// Shape of the final photo (width / height). 4:5 = Instagram portrait.
    static let photoAspect: CGFloat = 4.0 / 5.0

    static func bestFrame(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> CGRect {
        let bw = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let bh = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let sideways: [CGImagePropertyOrientation] = [.left, .right, .leftMirrored, .rightMirrored]
        let rotated = sideways.contains(orientation)
        let imgW = rotated ? bh : bw
        let imgH = rotated ? bw : bh

        // On-device "what would a person look at" map. Free, offline.
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        try? handler.perform([request])
        let objects = request.results?.first?.salientObjects ?? []

        let subject: CGRect
        if objects.isEmpty {
            subject = CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)
        } else {
            let sorted = objects.sorted { $0.confidence > $1.confidence }
            var box = sorted[0].boundingBox
            for o in sorted.dropFirst() where o.confidence > sorted[0].confidence * 0.6 {
                box = box.union(o.boundingBox)
            }
            subject = box
        }
        return frame(around: subject, imageAspect: imgW / imgH)
    }

    /// Builds a 4:5 frame around the subject using the rule of thirds.
    static func frame(around s: CGRect, imageAspect: CGFloat) -> CGRect {
        // Normalized width/height ratio that gives photoAspect in real pixels.
        let k = photoAspect / imageAspect

        // Subject fills roughly 60% of the frame.
        var fh = max(s.height / 0.6, (s.width / 0.6) / k)
        fh = min(max(fh, 0.4), 1.0)
        var fw = fh * k
        if fw > 1 { fw = 1; fh = fw / k }

        // Horizontal: put the subject on a third line, unless it's already centred.
        let off = s.midX - 0.5
        var cx: CGFloat
        if abs(off) < 0.08 {
            cx = s.midX
        } else if off < 0 {
            cx = s.midX + fw / 6   // subject lands on the left third
        } else {
            cx = s.midX - fw / 6   // subject lands on the right third
        }

        // Vertical: subject a bit above centre (Vision y goes up).
        var cy = s.midY - fh * 0.08

        // Keep the frame inside the image.
        cx = min(max(cx, fw / 2), 1 - fw / 2)
        cy = min(max(cy, fh / 2), 1 - fh / 2)
        return CGRect(x: cx - fw / 2, y: cy - fh / 2, width: fw, height: fh)
    }
}
