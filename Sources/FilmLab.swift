import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UIKit

/// Everything you can change about a photo in the editor. Saved with each shot, so edits can be redone.
struct EditSettings: Codable, Equatable {
    var look: String = "none"
    var intensity: Double = 1
    var exposure: Double = 0     // -1...1 EV
    var warmth: Double = 0       // -1...1
    var fade: Double = 0         // 0...1
    var grain: Double = 0        // 0...1
    var halation: Double = 0     // 0...1
    var vignette: Double = 0     // 0...1
    var frame: FrameStyle = .none
    var dateStamp: Bool = false

    var isPlain: Bool { self == EditSettings() }

    /// Builds settings from the AI's suggestion (loose JSON), clamped to safe ranges.
    static func fromAI(_ d: [String: Any]) -> EditSettings {
        func num(_ key: String) -> Double? { AIScout.number(d[key]) }
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }

        var s = EditSettings()
        let lookID = (d["look"] as? String)?.lowercased() ?? "none"
        s.apply(look: FilmLab.look(lookID))
        if let v = num("strength") { s.intensity = clamp(v, 0, 1) }
        if let v = num("exposure") { s.exposure = clamp(v, -1, 1) }
        if let v = num("warmth") { s.warmth = clamp(v, -1, 1) }
        if let v = num("fade") { s.fade = clamp(v, 0, 1) }
        if let v = num("grain") { s.grain = clamp(v, 0, 0.6) }
        if let v = num("halation") { s.halation = clamp(v, 0, 1) }
        if let v = num("vignette") { s.vignette = clamp(v, 0, 1) }
        if let f = (d["frame"] as? String).flatMap({ FrameStyle(rawValue: $0.lowercased()) }) { s.frame = f }
        if let b = d["dateStamp"] as? Bool { s.dateStamp = b }
        return s
    }

    /// Picking a look sets the sliders to that look's recipe.
    mutating func apply(look l: FilmLook) {
        look = l.id
        intensity = 1
        warmth = l.warmth
        fade = l.fade
        grain = l.grain
        halation = l.halation
        vignette = l.vignette
    }

    /// The look (and frame) applied automatically to new shots.
    static var forNewShots: EditSettings {
        get {
            guard let data = UserDefaults.standard.data(forKey: "defaultEdits"),
                  let s = try? JSONDecoder().decode(EditSettings.self, from: data) else { return EditSettings() }
            return s
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "defaultEdits")
        }
    }
}

struct FilmLook: Identifiable, Equatable {
    let id: String
    let name: String
    let saturation: Double
    let contrast: Double
    /// Per-channel curves: out = a0 + a1·x + a2·x² + a3·x³
    let red: CIVector
    let green: CIVector
    let blue: CIVector
    // Slider starting points for this look.
    let warmth: Double
    let fade: Double
    let grain: Double
    let halation: Double
    let vignette: Double
}

enum FilmLab {
    static let context = CIContext()

    private static let flat = CIVector(x: 0, y: 1, z: 0, w: 0)

    static let looks: [FilmLook] = [
        FilmLook(id: "none", name: "Original", saturation: 1, contrast: 1,
                 red: flat, green: flat, blue: flat,
                 warmth: 0, fade: 0, grain: 0, halation: 0, vignette: 0),
        FilmLook(id: "golden", name: "Golden 200", saturation: 1.03, contrast: 1.04,
                 red: CIVector(x: 0.03, y: 1.02, z: 0, w: -0.03),
                 green: CIVector(x: 0.01, y: 1.0, z: 0, w: -0.02),
                 blue: CIVector(x: 0, y: 0.92, z: 0, w: 0),
                 warmth: 0.2, fade: 0.08, grain: 0.15, halation: 0.1, vignette: 0.15),
        FilmLook(id: "soft", name: "Soft 400", saturation: 0.9, contrast: 0.95,
                 red: CIVector(x: 0.03, y: 0.97, z: 0, w: 0),
                 green: CIVector(x: 0.02, y: 0.97, z: 0, w: 0),
                 blue: CIVector(x: 0.03, y: 0.93, z: 0, w: 0),
                 warmth: 0.12, fade: 0.18, grain: 0.18, halation: 0.05, vignette: 0.08),
        FilmLook(id: "night", name: "Night 800", saturation: 0.95, contrast: 1.1,
                 red: CIVector(x: 0, y: 0.95, z: 0.1, w: -0.03),
                 green: CIVector(x: 0.02, y: 0.98, z: 0, w: 0),
                 blue: CIVector(x: 0.06, y: 0.9, z: -0.05, w: 0.05),
                 warmth: 0.08, fade: 0.12, grain: 0.3, halation: 0.4, vignette: 0.25),
        FilmLook(id: "slide", name: "Slide", saturation: 1.2, contrast: 1.15,
                 red: flat, green: flat,
                 blue: CIVector(x: 0.02, y: 1.02, z: 0, w: 0),
                 warmth: -0.12, fade: 0, grain: 0.1, halation: 0.05, vignette: 0.2),
        FilmLook(id: "faded", name: "Faded", saturation: 0.8, contrast: 0.9,
                 red: flat, green: flat, blue: flat,
                 warmth: 0.05, fade: 0.4, grain: 0.2, halation: 0, vignette: 0.12),
        FilmLook(id: "mono", name: "Mono", saturation: 0, contrast: 1.2,
                 red: flat, green: flat, blue: flat,
                 warmth: 0, fade: 0.1, grain: 0.3, halation: 0, vignette: 0.25),
        FilmLook(id: "noir", name: "Noir", saturation: 0, contrast: 1.45,
                 red: flat, green: flat, blue: flat,
                 warmth: 0, fade: 0, grain: 0.25, halation: 0, vignette: 0.4)
    ]

    static func look(_ id: String) -> FilmLook {
        looks.first { $0.id == id } ?? looks[0]
    }

    // MARK: Render

    static func render(_ input: CIImage, _ s: EditSettings) -> CIImage {
        let extent = input.extent
        let size = max(extent.width, extent.height)
        var img = input
        let look = look(s.look)
        let k = s.intensity

        if s.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = img
            f.ev = Float(s.exposure)
            img = f.outputImage ?? img
        }

        if look.id != "none" {
            let cc = CIFilter.colorControls()
            cc.inputImage = img
            cc.saturation = Float(lerp(1, look.saturation, k))
            cc.contrast = Float(lerp(1, look.contrast, k))
            cc.brightness = 0
            img = cc.outputImage ?? img

            let p = CIFilter.colorPolynomial()
            p.inputImage = img
            p.redCoefficients = mix(look.red, k)
            p.greenCoefficients = mix(look.green, k)
            p.blueCoefficients = mix(look.blue, k)
            p.alphaCoefficients = flat
            img = p.outputImage ?? img
        }

        if s.warmth != 0 {
            let w = CGFloat(s.warmth) * 0.12
            let m = CIFilter.colorMatrix()
            m.inputImage = img
            m.rVector = CIVector(x: 1 + w, y: 0, z: 0, w: 0)
            m.gVector = CIVector(x: 0, y: 1 + w * 0.3, z: 0, w: 0)
            m.bVector = CIVector(x: 0, y: 0, z: 1 - w, w: 0)
            m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            m.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            img = m.outputImage ?? img
        }

        if s.fade > 0 {
            let f = CGFloat(s.fade)
            let t = CIFilter.toneCurve()
            t.inputImage = img
            t.point0 = CGPoint(x: 0, y: 0.16 * f)
            t.point1 = CGPoint(x: 0.25, y: 0.25 + 0.07 * f)
            t.point2 = CGPoint(x: 0.5, y: 0.5 + 0.01 * f)
            t.point3 = CGPoint(x: 0.75, y: 0.75 - 0.02 * f)
            t.point4 = CGPoint(x: 1, y: 1 - 0.06 * f)
            img = t.outputImage ?? img
        }

        if s.halation > 0 {
            img = halation(img, amount: s.halation, size: size)
        }

        if s.vignette > 0 {
            let v = CIFilter.vignetteEffect()
            v.inputImage = img
            v.center = CGPoint(x: extent.midX, y: extent.midY)
            v.radius = Float(size * 0.62)
            v.intensity = Float(s.vignette * 0.9)
            v.falloff = 0.6
            img = v.outputImage ?? img
        }

        if s.grain > 0 {
            img = grain(img, amount: s.grain, size: size)
        }

        return img.cropped(to: extent)
    }

    /// Full-size render including frame and date stamp, ready to save.
    static func renderFinal(_ cg: CGImage, _ s: EditSettings, date: Date, specs: String) -> CGImage? {
        let input = CIImage(cgImage: cg)
        let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        guard let rendered = context.createCGImage(render(input, s), from: input.extent,
                                                   format: .RGBA8, colorSpace: space) else { return nil }
        if s.frame == .none && !s.dateStamp { return rendered }
        return FrameRenderer.apply(to: rendered, style: s.frame, dateStamp: s.dateStamp, date: date, specs: specs)
    }

    // MARK: Effects

    /// Red-orange glow bleeding out of the bright parts, like film.
    private static func halation(_ img: CIImage, amount: Double, size: CGFloat) -> CIImage {
        let extent = img.extent
        let lum = CIFilter.colorMatrix()
        lum.inputImage = img
        let weights = CIVector(x: 0.3, y: 0.59, z: 0.11, w: 0)
        lum.rVector = weights
        lum.gVector = weights
        lum.bVector = weights
        lum.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        lum.biasVector = CIVector(x: -0.7, y: -0.7, z: -0.7, w: 0)

        let clamp = CIFilter.colorClamp()
        clamp.inputImage = lum.outputImage
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)

        let a = CGFloat(amount) * 0.55
        let tint = CIFilter.colorMatrix()
        tint.inputImage = clamp.outputImage
        tint.rVector = CIVector(x: 3.2 * a, y: 0, z: 0, w: 0)
        tint.gVector = CIVector(x: 1.0 * a, y: 0, z: 0, w: 0)
        tint.bVector = CIVector(x: 0.35 * a, y: 0, z: 0, w: 0)
        tint.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        tint.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        guard let tinted = tint.outputImage else { return img }

        let glow = tinted.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(size) * 0.01)
            .cropped(to: extent)
        let add = CIFilter.additionCompositing()
        add.inputImage = glow
        add.backgroundImage = img
        return add.outputImage ?? img
    }

    /// Film grain, sized relative to the photo so preview and saved photo match.
    private static func grain(_ img: CIImage, amount: Double, size: CGFloat) -> CIImage {
        let extent = img.extent
        guard let random = CIFilter.randomGenerator().outputImage else { return img }

        // The generator's alpha is random too; laying it over black makes it opaque
        // without blowing the colour values up (that was the white-speck bug).
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
        let scale = max(size / 1600, 0.25)
        let opaque = random
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: extent)
            .composited(over: black)

        // One channel only = monochrome grain, centred on mid-grey.
        let amp = CGFloat(amount) * 0.22
        let m = CIFilter.colorMatrix()
        m.inputImage = opaque
        let v = CIVector(x: 0, y: amp, z: 0, w: 0)
        m.rVector = v
        m.gVector = v
        m.bVector = v
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        let bias = 0.5 - amp / 2
        m.biasVector = CIVector(x: bias, y: bias, z: bias, w: 1)
        guard let flat = m.outputImage else { return img }

        // Soften slightly so it reads as grain, not digital noise.
        let soft = flat.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(max(scale, 1)) * 0.45)
            .cropped(to: extent)

        let blend = CIFilter.softLightBlendMode()
        blend.inputImage = soft
        blend.backgroundImage = img
        return blend.outputImage ?? img
    }

    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    /// Blends a curve toward "no change" by intensity.
    private static func mix(_ v: CIVector, _ t: Double) -> CIVector {
        let t = CGFloat(t)
        return CIVector(x: v.x * t, y: 1 + (v.y - 1) * t, z: v.z * t, w: v.w * t)
    }

    static func downscale(_ img: CIImage, to longSide: CGFloat) -> CIImage {
        let s = longSide / max(img.extent.width, img.extent.height)
        guard s < 1 else { return img }
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = img
        f.scale = Float(s)
        f.aspectRatio = 1
        return f.outputImage ?? img
    }
}

/// "24mm · f/1.8 · 1/120s · ISO 400" from the photo's EXIF.
enum PhotoSpecs {
    static func describe(_ meta: [String: Any]) -> String {
        guard let exif = meta[kCGImagePropertyExifDictionary as String] as? [String: Any] else { return "" }
        var parts: [String] = []
        if let mm = exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? Int {
            parts.append("\(mm)mm")
        }
        if let f = exif[kCGImagePropertyExifFNumber as String] as? Double {
            parts.append(String(format: "f/%.1f", f))
        }
        if let t = exif[kCGImagePropertyExifExposureTime as String] as? Double, t > 0 {
            parts.append(t >= 1 ? String(format: "%.1fs", t) : "1/\(Int((1 / t).rounded()))s")
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first {
            parts.append("ISO \(iso)")
        }
        return parts.joined(separator: "  ·  ")
    }

    static func metadata(of url: URL) -> [String: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return [:] }
        return props
    }
}
