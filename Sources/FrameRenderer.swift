import UIKit

enum FrameStyle: String, Codable, CaseIterable, Identifiable {
    case none, white, paper, film, black, specs

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .white: return "White"
        case .paper: return "Paper"
        case .film: return "Film edge"
        case .black: return "Black"
        case .specs: return "Specs"
        }
    }
}

/// Draws borders, the specs strip and the film-style date stamp.
enum FrameRenderer {
    static func apply(to image: CGImage, style: FrameStyle, dateStamp: Bool, date: Date, specs: String) -> CGImage {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let unit = min(w, h)

        var top: CGFloat = 0
        var side: CGFloat = 0
        var bottom: CGFloat = 0
        var bg = UIColor.white
        switch style {
        case .none:
            break
        case .white:
            top = unit * 0.04; side = unit * 0.04; bottom = unit * 0.04
        case .paper:
            top = unit * 0.05; side = unit * 0.05; bottom = unit * 0.17
            bg = UIColor(red: 0.96, green: 0.945, blue: 0.915, alpha: 1)
        case .film:
            top = unit * 0.045; side = unit * 0.045; bottom = unit * 0.045
            bg = UIColor(red: 0.97, green: 0.965, blue: 0.95, alpha: 1)
        case .black:
            top = unit * 0.03; side = unit * 0.03; bottom = unit * 0.03
            bg = .black
        case .specs:
            top = unit * 0.04; side = unit * 0.04; bottom = unit * 0.12
        }

        let size = CGSize(width: w + 2 * side, height: h + top + bottom)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let out = renderer.image { ctx in
            bg.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            let photoRect = CGRect(x: side, y: top, width: w, height: h)
            if style == .film {
                // Rough, slightly uneven edges like a darkroom print.
                ctx.cgContext.saveGState()
                roughEdge(around: photoRect, depth: unit * 0.01).addClip()
                UIImage(cgImage: image).draw(in: photoRect)
                ctx.cgContext.restoreGState()
            } else {
                UIImage(cgImage: image).draw(in: photoRect)
            }

            if dateStamp {
                drawDateStamp(date, in: photoRect, unit: unit)
            }
            if style == .specs {
                let strip = CGRect(x: side, y: top + h, width: w, height: bottom)
                drawSpecs(specs, date: date, in: strip, unit: unit)
            }
        }
        return out.cgImage ?? image
    }

    /// A rectangle whose edges wander inward a little, the same way every time.
    private static func roughEdge(around r: CGRect, depth: CGFloat) -> UIBezierPath {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func rand() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(Double(seed >> 11) / Double(UInt64(1) << 53))
        }
        let steps = 140
        var wander: CGFloat = depth * 0.5
        func nextInset() -> CGFloat {
            wander = min(max(wander + (rand() - 0.5) * depth * 0.55, 0), depth)
            return wander
        }
        let path = UIBezierPath()
        path.move(to: CGPoint(x: r.minX + nextInset(), y: r.minY + nextInset()))
        for i in 1...steps {      // top
            let x = r.minX + r.width * CGFloat(i) / CGFloat(steps)
            path.addLine(to: CGPoint(x: x, y: r.minY + nextInset()))
        }
        for i in 1...steps {      // right
            let y = r.minY + r.height * CGFloat(i) / CGFloat(steps)
            path.addLine(to: CGPoint(x: r.maxX - nextInset(), y: y))
        }
        for i in 1...steps {      // bottom
            let x = r.maxX - r.width * CGFloat(i) / CGFloat(steps)
            path.addLine(to: CGPoint(x: x, y: r.maxY - nextInset()))
        }
        for i in 1...steps {      // left
            let y = r.maxY - r.height * CGFloat(i) / CGFloat(steps)
            path.addLine(to: CGPoint(x: r.minX + nextInset(), y: y))
        }
        path.close()
        return path
    }

    private static func drawDateStamp(_ date: Date, in rect: CGRect, unit: CGFloat) {
        let formatter = DateFormatter()
        formatter.dateFormat = "''yy MM dd"
        let text = formatter.string(from: date)

        let orange = UIColor(red: 1.0, green: 0.55, blue: 0.15, alpha: 0.95)
        let glow = NSShadow()
        glow.shadowColor = orange.withAlphaComponent(0.8)
        glow.shadowBlurRadius = unit * 0.008
        glow.shadowOffset = .zero

        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: unit * 0.042, weight: .semibold),
            .foregroundColor: orange,
            .shadow: glow
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let s = str.size()
        let inset = unit * 0.05
        str.draw(at: CGPoint(x: rect.maxX - s.width - inset, y: rect.maxY - s.height - inset))
    }

    private static func drawSpecs(_ specs: String, date: Date, in strip: CGRect, unit: CGFloat) {
        let ink = UIColor(white: 0.2, alpha: 1)
        let font = UIFont.systemFont(ofSize: unit * 0.027, weight: .medium)

        let left = NSAttributedString(string: specs.isEmpty ? "Aimshot" : specs,
                                      attributes: [.font: font, .foregroundColor: ink])
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        let right = NSAttributedString(string: formatter.string(from: date),
                                       attributes: [.font: font, .foregroundColor: ink.withAlphaComponent(0.6)])

        let ls = left.size()
        let rs = right.size()
        let y = strip.midY - ls.height / 2
        left.draw(at: CGPoint(x: strip.minX, y: y))
        right.draw(at: CGPoint(x: strip.maxX - rs.width, y: strip.midY - rs.height / 2))
    }
}
