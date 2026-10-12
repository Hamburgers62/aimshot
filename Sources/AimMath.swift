import CoreMotion
import CoreGraphics
import simd

/// A shot pinned to a direction in the room, so it stays put while the phone moves.
struct AimTarget: Equatable {
    var worldDir: SIMD3<Double>   // unit ray in the motion reference frame
    var tanWidth: Double          // frame size on an image plane 1 unit in front of the camera
    var tanHeight: Double
    var subject: String
    var why: String
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

    /// A normalized Vision rect (origin bottom-left) seen at attitude `r` and `zoom` -> a target in the room.
    static func target(from rect: CGRect, r: simd_double3x3, zoom: Double, geo: CameraGeometry,
                       subject: String, why: String) -> AimTarget {
        let hw = geo.halfW(zoom: zoom)
        let hh = geo.halfH(zoom: zoom)
        let x = (Double(rect.midX) - 0.5) * 2 * hw
        let y = (Double(rect.midY) - 0.5) * 2 * hh
        // Back camera looks down the device's -z axis; image right = +x, image up = +y.
        let dev = simd_normalize(SIMD3(x, y, -1))
        return AimTarget(worldDir: toWorld(dev, r),
                         tanWidth: Double(rect.width) * 2 * hw,
                         tanHeight: Double(rect.height) * 2 * hh,
                         subject: subject,
                         why: why)
    }

    /// Where the target sits in the view right now (normalized Vision rect). nil if it's behind you.
    static func project(_ t: AimTarget, r: simd_double3x3, zoom: Double, geo: CameraGeometry) -> CGRect? {
        let v = toDevice(t.worldDir, r)
        guard v.z < -0.05 else { return nil }
        let px = v.x / -v.z
        let py = v.y / -v.z
        let hw = geo.halfW(zoom: zoom)
        let hh = geo.halfH(zoom: zoom)
        let u = 0.5 + px / (2 * hw)
        let w = 0.5 + py / (2 * hh)
        let bw = t.tanWidth / (2 * hw)
        let bh = t.tanHeight / (2 * hh)
        return CGRect(x: u - bw / 2, y: w - bh / 2, width: bw, height: bh)
    }

    /// Zoom factor that makes the frame fill about 92% of the view.
    static func fillZoom(for t: AimTarget, geo: CameraGeometry) -> Double {
        0.92 * min(2 * geo.tanHalfW / t.tanWidth, 2 * geo.tanHalfH / t.tanHeight)
    }
}
