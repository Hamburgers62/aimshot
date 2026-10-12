import AVFoundation
import CoreMotion
import CoreGraphics
import simd

/// How the phone is being held.
enum ShotOrientation: Equatable {
    case portrait
    case landscapeTopLeft    // turned left (counter-clockwise)
    case landscapeTopRight   // turned right (clockwise)

    var isLandscape: Bool { self != .portrait }

    /// Turns a raw back-camera frame upright for this way of holding the phone.
    var bufferOrientation: CGImagePropertyOrientation {
        switch self {
        case .portrait: return .right
        case .landscapeTopLeft: return .up
        case .landscapeTopRight: return .down
        }
    }

    /// Photo connection rotation (iOS 17+).
    var rotationAngle: CGFloat {
        switch self {
        case .portrait: return 90
        case .landscapeTopLeft: return 0
        case .landscapeTopRight: return 180
        }
    }

    /// Photo connection orientation (iOS 16).
    var legacyVideoOrientation: AVCaptureVideoOrientation {
        switch self {
        case .portrait: return .portrait
        case .landscapeTopLeft: return .landscapeRight
        case .landscapeTopRight: return .landscapeLeft
        }
    }

    /// Rotation for on-screen icons so they read upright.
    var iconDegrees: Double {
        switch self {
        case .portrait: return 0
        case .landscapeTopLeft: return 90
        case .landscapeTopRight: return -90
        }
    }
}

/// Converts rects between the portrait preview and an image held another way.
/// All rects here are normalized with origin top-left.
enum OrientMath {
    /// Rect in an upright image taken in `o` -> rect in the portrait preview.
    static func toPortrait(_ r: CGRect, from o: ShotOrientation) -> CGRect {
        switch o {
        case .portrait:
            return r
        case .landscapeTopRight:
            return CGRect(x: r.minY, y: 1 - r.maxX, width: r.height, height: r.width)
        case .landscapeTopLeft:
            return CGRect(x: 1 - r.maxY, y: r.minX, width: r.height, height: r.width)
        }
    }

    /// Rect in the portrait preview -> rect in an upright image taken in `o`.
    static func fromPortrait(_ r: CGRect, to o: ShotOrientation) -> CGRect {
        switch o {
        case .portrait:
            return r
        case .landscapeTopRight:
            return CGRect(x: 1 - r.maxY, y: r.minX, width: r.height, height: r.width)
        case .landscapeTopLeft:
            return CGRect(x: r.minY, y: 1 - r.maxX, width: r.height, height: r.width)
        }
    }

    /// Flips between origin top-left and Vision's origin bottom-left (works both ways).
    static func flipY(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }
}

/// A shot pinned to a direction in the room, so it stays put while the phone moves.
struct AimTarget: Equatable {
    var worldDir: SIMD3<Double>   // unit ray in the motion reference frame
    var tanWidth: Double          // frame size on an image plane 1 unit in front of the camera
    var tanHeight: Double
    var landscape: Bool           // how the phone was held when this frame was picked
    var subject: String
    var why: String
    var score: Int = 0            // AI's 1-10 rating (0 = not rated)
    var exposure: Double = 0      // AI's suggested exposure tweak in EV
    var refined: Bool = false     // already fine-tuned up close
}

/// Field of view of the upright (portrait) camera view at videoZoomFactor 1.
struct CameraGeometry {
    var tanHalfW: Double
    var tanHalfH: Double

    func halfW(zoom: Double) -> Double { tanHalfW / max(zoom, 0.01) }
    func halfH(zoom: Double) -> Double { tanHalfH / max(zoom, 0.01) }
}

enum AimMath {
    /// Which way CoreMotion's rotation matrix points, learned from gravity at runtime.
    /// true = the matrix maps reference-frame vectors into the device frame.
    static var refToDevice = true
    static var conventionLocked = false

    static func matrix(_ m: CMRotationMatrix) -> simd_double3x3 {
        simd_double3x3(rows: [
            SIMD3(m.m11, m.m12, m.m13),
            SIMD3(m.m21, m.m22, m.m23),
            SIMD3(m.m31, m.m32, m.m33)
        ])
    }

    static func learnConvention(from motion: CMDeviceMotion) {
        if conventionLocked { return }
        let r = motion.attitude.rotationMatrix
        let g = SIMD3(motion.gravity.x, motion.gravity.y, motion.gravity.z)
        let a = SIMD3(-r.m13, -r.m23, -r.m33)   // R * (0,0,-1)
        let b = SIMD3(-r.m31, -r.m32, -r.m33)   // Rᵀ * (0,0,-1)
        let da = simd_dot(a, g)
        let db = simd_dot(b, g)
        if abs(da - db) > 0.5 {
            refToDevice = da > db
            conventionLocked = true
        }
    }

    static func toWorld(_ v: SIMD3<Double>, _ r: simd_double3x3) -> SIMD3<Double> {
        refToDevice ? r.transpose * v : r * v
    }

    static func toDevice(_ w: SIMD3<Double>, _ r: simd_double3x3) -> SIMD3<Double> {
        refToDevice ? r * w : r.transpose * w
    }

    /// A Vision rect in the portrait preview, seen at attitude `r` and `zoom` -> a target in the room.
    static func target(from rect: CGRect, r: simd_double3x3, zoom: Double, geo: CameraGeometry,
                       landscape: Bool, subject: String, why: String,
                       score: Int = 0, exposure: Double = 0) -> AimTarget {
        let hw = geo.halfW(zoom: zoom)
        let hh = geo.halfH(zoom: zoom)
        let x = (Double(rect.midX) - 0.5) * 2 * hw
        let y = (Double(rect.midY) - 0.5) * 2 * hh
        // Back camera looks down the device's -z axis; image right = +x, image up = +y.
        let dev = simd_normalize(SIMD3(x, y, -1))
        return AimTarget(worldDir: toWorld(dev, r),
                         tanWidth: Double(rect.width) * 2 * hw,
                         tanHeight: Double(rect.height) * 2 * hh,
                         landscape: landscape,
                         subject: subject,
                         why: why,
                         score: score,
                         exposure: exposure)
    }

    /// Where the target sits in the portrait preview now (Vision rect). nil if it's behind you.
    /// If the phone has been turned since the frame was picked, the box turns with it.
    static func project(_ t: AimTarget, r: simd_double3x3, zoom: Double, geo: CameraGeometry,
                        landscapeNow: Bool) -> CGRect? {
        let v = toDevice(t.worldDir, r)
        guard v.z < -0.05 else { return nil }
        let px = v.x / -v.z
        let py = v.y / -v.z
        let hw = geo.halfW(zoom: zoom)
        let hh = geo.halfH(zoom: zoom)
        let u = 0.5 + px / (2 * hw)
        let w = 0.5 + py / (2 * hh)
        let swap = t.landscape != landscapeNow
        let tw = swap ? t.tanHeight : t.tanWidth
        let th = swap ? t.tanWidth : t.tanHeight
        let bw = tw / (2 * hw)
        let bh = th / (2 * hh)
        return CGRect(x: u - bw / 2, y: w - bh / 2, width: bw, height: bh)
    }
}
