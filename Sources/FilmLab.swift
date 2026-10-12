import CoreImage
import simd
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

/// How a look treats colour and tone. Baked into a 3D colour table (LUT), like pro film presets.
struct LookRecipe: Equatable {
    var contrast: Double = 0          // film S-curve strength (0 = none, ~3 gentle, ~8 hard)
    var lift: Double = 0              // lifted blacks (matte shadows)
    var shoulder: Double = 0          // rolled-off highlights (softer whites)
    var saturation: Double = 1
    var highlightDesat: Double = 0.3  // colours calm down in bright areas, like film
    var shadowDesat: Double = 0.2     // ...and in dark areas
    var shadowTint = SIMD3<Double>(0, 0, 0)
    var highlightTint = SIMD3<Double>(0, 0, 0)
    var greenShift: Double = 0        // greens toward olive
    var blueShift: Double = 0         // blues toward teal
    var mono: SIMD3<Double>? = nil    // black and white channel mix
}

struct FilmLook: Identifiable, Equatable {
    let id: String
    let name: String
    let recipe: LookRecipe
    // Slider starting points for this look (kept subtle on purpose).
    let warmth: Double
    let fade: Double
    let grain: Double
    let halation: Double
    let vignette: Double
    /// The look's own brightness shift in stops (moody looks sit darker).
    var ev: Double = 0
}

enum FilmLab {
    static let context = CIContext()

    static let looks: [FilmLook] = [
        FilmLook(id: "none", name: "Original", recipe: LookRecipe(),
                 warmth: 0, fade: 0, grain: 0, halation: 0, vignette: 0),
        FilmLook(id: "natural", name: "Natural",
                 recipe: LookRecipe(contrast: 2.5, lift: 0.015, shoulder: 0.02, saturation: 1.02,
                                    highlightDesat: 0.2, shadowDesat: 0.1,
                                    shadowTint: SIMD3(0, 0.003, 0.008), highlightTint: SIMD3(0.012, 0.006, 0),
                                    greenShift: 0.2),
                 warmth: 0.03, fade: 0, grain: 0.05, halation: 0, vignette: 0),
        FilmLook(id: "golden", name: "Golden 200",
                 recipe: LookRecipe(contrast: 4, lift: 0.035, shoulder: 0.04, saturation: 1.05,
                                    highlightDesat: 0.3, shadowDesat: 0.2,
                                    shadowTint: SIMD3(0.005, 0.005, 0.02), highlightTint: SIMD3(0.04, 0.022, -0.02),
                                    greenShift: 0.5, blueShift: 0.2),
                 warmth: 0.1, fade: 0.03, grain: 0.12, halation: 0.05, vignette: 0.05),
        FilmLook(id: "soft", name: "Soft 400",
                 recipe: LookRecipe(contrast: 3, lift: 0.05, shoulder: 0.05, saturation: 0.92,
                                    highlightDesat: 0.35, shadowDesat: 0.25,
                                    shadowTint: SIMD3(-0.005, 0.01, 0.018), highlightTint: SIMD3(0.03, 0.02, 0.005),
                                    greenShift: 0.4, blueShift: 0.3),
                 warmth: 0.05, fade: 0.04, grain: 0.1, halation: 0, vignette: 0),
        FilmLook(id: "night", name: "Night 800",
                 recipe: LookRecipe(contrast: 5, lift: 0.03, shoulder: 0.03, saturation: 0.95,
                                    highlightDesat: 0.35, shadowDesat: 0.3,
                                    shadowTint: SIMD3(-0.015, 0.012, 0.035), highlightTint: SIMD3(0.04, 0.015, -0.02),
                                    greenShift: 0.3, blueShift: 0.6),
                 warmth: 0, fade: 0.02, grain: 0.15, halation: 0.18, vignette: 0.06),
        FilmLook(id: "ember", name: "Ember",
                 recipe: LookRecipe(contrast: 5.5, lift: 0.02, shoulder: 0.07, saturation: 0.9,
                                    highlightDesat: 0.4, shadowDesat: 0.35,
                                    shadowTint: SIMD3(0.018, 0.0, -0.008), highlightTint: SIMD3(0.05, 0.02, -0.03),
                                    greenShift: 0.6, blueShift: 0.3),
                 warmth: 0.06, fade: 0, grain: 0.12, halation: 0.1, vignette: 0.12, ev: -0.3),
        FilmLook(id: "tide", name: "Tide",
                 recipe: LookRecipe(contrast: 4.5, lift: 0.045, shoulder: 0.04, saturation: 0.82,
                                    highlightDesat: 0.35, shadowDesat: 0.3,
                                    shadowTint: SIMD3(-0.012, 0.01, 0.035), highlightTint: SIMD3(0.005, 0.01, 0.012),
                                    greenShift: 0.3, blueShift: 0.7),
                 warmth: -0.06, fade: 0.03, grain: 0.1, halation: 0, vignette: 0.08, ev: -0.2),
        FilmLook(id: "slide", name: "Slide",
                 recipe: LookRecipe(contrast: 6, lift: 0, shoulder: 0.015, saturation: 1.15,
                                    highlightDesat: 0.15, shadowDesat: 0.1,
                                    shadowTint: SIMD3(0, 0, 0.015), highlightTint: SIMD3(0.01, 0.005, 0),
                                    greenShift: 0.1, blueShift: 0.2),
                 warmth: -0.03, fade: 0, grain: 0.06, halation: 0, vignette: 0.04),
        FilmLook(id: "faded", name: "Faded",
                 recipe: LookRecipe(contrast: 2.5, lift: 0.11, shoulder: 0.07, saturation: 0.82,
                                    highlightDesat: 0.3, shadowDesat: 0.3,
                                    shadowTint: SIMD3(0, 0.008, 0.02), highlightTint: SIMD3(0.02, 0.015, 0.0),
                                    greenShift: 0.4, blueShift: 0.4),
                 warmth: 0.03, fade: 0, grain: 0.1, halation: 0, vignette: 0),
        FilmLook(id: "mono", name: "Mono",
                 recipe: LookRecipe(contrast: 4.5, lift: 0.03, shoulder: 0.03,
                                    shadowTint: SIMD3(0, 0, 0.006), highlightTint: SIMD3(0.008, 0.004, 0),
                                    mono: SIMD3(0.32, 0.52, 0.16)),
                 warmth: 0, fade: 0.03, grain: 0.15, halation: 0, vignette: 0.04),
        FilmLook(id: "noir", name: "Noir",
                 recipe: LookRecipe(contrast: 8, lift: 0, shoulder: 0.01,
                                    mono: SIMD3(0.5, 0.4, 0.1)),
                 warmth: 0, fade: 0, grain: 0.12, halation: 0, vignette: 0.1)
    ]

    static func look(_ id: String) -> FilmLook {
        looks.first { $0.id == id } ?? looks[0]
    }

    // MARK: Colour tables

    private static let lutSize = 33
    private static var lutCache: [String: Data] = [:]
    private static let lutLock = NSLock()

    /// The look's 3D colour table, built once and cached.
    static func lut(for look: FilmLook) -> Data {
        lutLock.lock()
        defer { lutLock.unlock() }
        if let d = lutCache[look.id] { return d }
        let n = lutSize
        var cube = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let step = 1.0 / Double(n - 1)
                    let rgb = SIMD3<Double>(Double(r) * step, Double(g) * step, Double(b) * step)
                    let o = grade(rgb, look.recipe)
                    cube[i] = Float(o.x)
                    cube[i + 1] = Float(o.y)
                    cube[i + 2] = Float(o.z)
                    cube[i + 3] = 1
                    i += 4
                }
            }
        }
        let data = cube.withUnsafeBufferPointer { Data(buffer: $0) }
        lutCache[look.id] = data
        return data
    }

    /// One colour through the look (values 0...1, display gamma).
    static func grade(_ input: SIMD3<Double>, _ p: LookRecipe) -> SIMD3<Double> {
        var c = input

        // Hue moves: greens toward olive, blues toward teal (protects skin tones).
        if p.greenShift != 0 || p.blueShift != 0 {
            var (h, s, v) = rgbToHSV(c)
            let greenW = bump(h, centre: 0.33, width: 0.12) * p.greenShift
            let blueW = bump(h, centre: 0.62, width: 0.1) * p.blueShift
            h += (0.2 - h) * 0.35 * greenW
            s *= 1 - 0.2 * greenW
            h += (0.53 - h) * 0.4 * blueW
            c = hsvToRGB(h, s, v)
        }

        if let m = p.mono {
            let y = simd_dot(c, m)
            c = SIMD3(repeating: y)
        }

        // Film tone curve.
        c = SIMD3(curve(c.x, p), curve(c.y, p), curve(c.z, p))

        // Colour calms down in highlights and shadows.
        let y: Double = simd_dot(c, SIMD3<Double>(0.2126, 0.7152, 0.0722))
        let hi = smoothstep(0.65, 1.0, y)
        let lo = 1 - smoothstep(0.0, 0.3, y)
        let sat = p.saturation * (1 - p.highlightDesat * hi) * (1 - p.shadowDesat * lo)
        let grey = SIMD3<Double>(repeating: y)
        let chroma: SIMD3<Double> = (c - grey) * sat
        c = grey + chroma

        // Split toning.
        let shadowWeight: Double = (1 - y) * (1 - y)
        let highlightWeight: Double = y * y
        let shadowPart: SIMD3<Double> = p.shadowTint * shadowWeight
        let highlightPart: SIMD3<Double> = p.highlightTint * highlightWeight
        c += shadowPart
        c += highlightPart

        let zero = SIMD3<Double>(repeating: 0)
        let one = SIMD3<Double>(repeating: 1)
        return simd_clamp(c, zero, one)
    }

    private static func curve(_ x: Double, _ p: LookRecipe) -> Double {
        var s = x
        if p.contrast > 0.01 {
            let k = p.contrast
            func sig(_ v: Double) -> Double { 1 / (1 + exp(-k * v)) }
            let lo = sig(-0.5)
            let hi = sig(0.5)
            s = (sig(x - 0.5) - lo) / (hi - lo)
        }
        return p.lift + (1 - p.lift - p.shoulder) * s
    }

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// 1 at the centre hue, fading to 0 at +/- width (hue wraps around).
    private static func bump(_ h: Double, centre: Double, width: Double) -> Double {
        var d = abs(h - centre)
        if d > 0.5 { d = 1 - d }
        return max(0, 1 - d / width)
    }

    private static func rgbToHSV(_ c: SIMD3<Double>) -> (Double, Double, Double) {
        let mx = max(c.x, c.y, c.z)
        let mn = min(c.x, c.y, c.z)
        let d = mx - mn
        var h = 0.0
        if d > 1e-6 {
            if mx == c.x { h = ((c.y - c.z) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == c.y { h = (c.z - c.x) / d + 2 }
            else { h = (c.x - c.y) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        let s = mx > 1e-6 ? d / mx : 0
        return (h, s, mx)
    }

    private static func hsvToRGB(_ hIn: Double, _ s: Double, _ v: Double) -> SIMD3<Double> {
        var h = hIn.truncatingRemainder(dividingBy: 1)
        if h < 0 { h += 1 }
        let i = floor(h * 6)
        let f = h * 6 - i
        let p = v * (1 - s)
        let q = v * (1 - f * s)
        let t = v * (1 - (1 - f) * s)
        switch Int(i) % 6 {
        case 0: return SIMD3(v, t, p)
        case 1: return SIMD3(q, v, p)
        case 2: return SIMD3(p, v, t)
        case 3: return SIMD3(p, q, v)
        case 4: return SIMD3(t, p, v)
        default: return SIMD3(v, p, q)
        }
    }

    // MARK: Render

    static func render(_ input: CIImage, _ s: EditSettings) -> CIImage {
        let extent = input.extent
        let size = max(extent.width, extent.height)
        var img = input
        let look = look(s.look)
        let k = s.intensity

        if s.exposure != 0 || look.ev != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = img
            f.ev = Float(s.exposure + look.ev * k)
            img = f.outputImage ?? img
        }

        // White balance goes before the look, like on a real camera.
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

        if look.id != "none", k > 0.001 {
            let cube = CIFilter.colorCubeWithColorSpace()
            cube.inputImage = img
            cube.cubeDimension = Float(lutSize)
            cube.cubeData = lut(for: look)
            cube.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            if let graded = cube.outputImage {
                if k >= 0.999 {
                    img = graded
                } else {
                    let mix = CIFilter.dissolveTransition()
                    mix.inputImage = img
                    mix.targetImage = graded
                    mix.time = Float(k)
                    img = mix.outputImage ?? graded
                }
            }
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
        lum.biasVector = CIVector(x: -0.8, y: -0.8, z: -0.8, w: 0)

        let clamp = CIFilter.colorClamp()
        clamp.inputImage = lum.outputImage
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)

        let a = CGFloat(amount) * 0.55
        let tint = CIFilter.colorMatrix()
        tint.inputImage = clamp.outputImage
        tint.rVector = CIVector(x: 4.5 * a, y: 0, z: 0, w: 0)
        tint.gVector = CIVector(x: 1.4 * a, y: 0, z: 0, w: 0)
        tint.bVector = CIVector(x: 0.5 * a, y: 0, z: 0, w: 0)
        tint.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        tint.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        guard let tinted = tint.outputImage else { return img }

        let glow = tinted.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(size) * 0.007)
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
