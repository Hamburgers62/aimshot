import Vision
import CoreGraphics
import CoreVideo

/// Basic on-device "best shot" guess, used when there's no API key.
enum Composer {
    /// Returns a frame (normalized, origin top-left) in the upright image.
    /// `wOverH` is the photo's width / height in pixels.
    static func bestFrame(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation,
                          wOverH: CGFloat) -> CGRect {
        let bw = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let bh = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let sideways: [CGImagePropertyOrientation] = [.left, .right, .leftMirrored, .rightMirrored]
        let rotated = sideways.contains(orientation)
        let imgW = rotated ? bh : bw
        let imgH = rotated ? bw : bh

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
        let vision = frame(around: subject, imageAspect: imgW / imgH, photoAspect: wOverH)
        return CGRect(x: vision.minX, y: 1 - vision.maxY, width: vision.width, height: vision.height)
    }

    /// Builds a frame around the subject using the rule of thirds (Vision coords in and out).
    static func frame(around s: CGRect, imageAspect: CGFloat, photoAspect: CGFloat) -> CGRect {
        let k = photoAspect / imageAspect

        var fh = max(s.height / 0.6, (s.width / 0.6) / k)
        fh = min(max(fh, 0.4), 1.0)
        var fw = fh * k
        if fw > 1 { fw = 1; fh = fw / k }

        let off = s.midX - 0.5
        var cx: CGFloat
        if abs(off) < 0.08 {
            cx = s.midX
        } else if off < 0 {
            cx = s.midX + fw / 6
        } else {
            cx = s.midX - fw / 6
        }
        var cy = s.midY - fh * 0.08

        cx = min(max(cx, fw / 2), 1 - fw / 2)
        cy = min(max(cy, fh / 2), 1 - fh / 2)
        return CGRect(x: cx - fw / 2, y: cy - fh / 2, width: fw, height: fh)
    }
}
