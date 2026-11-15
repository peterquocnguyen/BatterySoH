import AppKit
import CoreText

/// SPEC F1 menu bar glyph, drawn like macOS's own battery item: a filled rounded pill whose
/// charged part is opaque and the rest translucent, the percent knocked out of it, a terminal
/// nub, and a bolt when on power. It is a template image, so the menu bar tints it for its
/// appearance (black on light, white on dark, vibrant on wallpaper tint).
enum MenuBarGlyph {
    /// Point size of the image; the menu bar is ≈ 22 pt tall and centres it.
    static let size = NSSize(width: 27, height: 13)

    struct Style: Hashable {
        /// Number drawn inside the pill, nil for fill only.
        var percentText: String?
        /// Charged fraction, quantised to whole percent so images can be cached.
        var percent: Int
        var showsBolt: Bool
        /// Low Power Mode: yellow fill with dark content, like macOS's own item. Not a template
        /// image then (template images can't carry colour), so the track needs the appearance.
        var lowPower: Bool = false
        /// Menu bar appearance, used only when `lowPower` (template images tint themselves).
        var darkMenuBar: Bool = false
        /// 1 for the menu bar; larger to inspect the glyph in the render gallery.
        var pointScale: CGFloat = 1
    }

    @MainActor private static var cache: [Style: NSImage] = [:]

    @MainActor
    static func image(_ style: Style) -> NSImage {
        if let image = cache[style] { return image }
        let scaled = NSSize(width: size.width * style.pointScale, height: size.height * style.pointScale)
        let image = NSImage(size: scaled, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.scaleBy(x: style.pointScale, y: style.pointScale)
            draw(style, in: ctx)
            return true
        }
        image.isTemplate = !style.lowPower
        if cache.count > 64 { cache.removeAll() }
        cache[style] = image
        return image
    }

    // MARK: Geometry (points)

    static let pill = CGRect(x: 0.5, y: 0.5, width: 23.5, height: 12)
    static let pillRadius: CGFloat = 4
    static let nub = CGRect(x: 25, y: 4.25, width: 1.75, height: 4.5)
    /// Alpha of the uncharged part of the pill and of the nub.
    static let trackAlpha: CGFloat = 0.38

    /// macOS's Low Power yellow in the menu bar.
    static let lowPowerYellow = CGColor(srgbRed: 1.0, green: 0.80, blue: 0.04, alpha: 1)

    static func draw(_ style: Style, in ctx: CGContext) {
        if style.lowPower { return drawLowPower(style, in: ctx) }
        let black = CGColor(gray: 0, alpha: 1)
        let pillPath = CGPath(roundedRect: pill, cornerWidth: pillRadius, cornerHeight: pillRadius, transform: nil)
        let fraction = min(1, max(0, CGFloat(style.percent) / 100))
        let filled = CGRect(x: pill.minX, y: pill.minY, width: pill.width * fraction, height: pill.height)
        let track = CGRect(x: filled.maxX, y: pill.minY, width: pill.maxX - filled.maxX, height: pill.height)

        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.saveGState()
        ctx.addPath(pillPath)
        ctx.clip()
        ctx.setFillColor(black.copy(alpha: trackAlpha)!)
        ctx.fill(pill)
        ctx.setFillColor(black)
        ctx.fill(filled)

        // Content (number + bolt): knocked out of the charged part, solid over the track,
        // so it stays readable at any charge level.
        let content = Content(style)
        ctx.saveGState()
        ctx.clip(to: filled)
        ctx.setBlendMode(.destinationOut)
        content.draw(in: ctx)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.clip(to: track)
        content.draw(in: ctx)
        ctx.restoreGState()
        ctx.restoreGState()
        ctx.endTransparencyLayer()

        // Terminal nub: half-capsule on the right.
        ctx.setFillColor(black.copy(alpha: fraction >= 1 ? 1 : trackAlpha)!)
        ctx.addPath(nubPath())
        ctx.fillPath()
    }

    /// Coloured variant: yellow charged part, appearance-tinted track, dark number and bolt
    /// drawn solid over both (as macOS does in Low Power Mode).
    static func drawLowPower(_ style: Style, in ctx: CGContext) {
        let ink = CGColor(gray: style.darkMenuBar ? 1 : 0, alpha: trackAlpha)
        let pillPath = CGPath(roundedRect: pill, cornerWidth: pillRadius, cornerHeight: pillRadius, transform: nil)
        let fraction = min(1, max(0, CGFloat(style.percent) / 100))
        let filled = CGRect(x: pill.minX, y: pill.minY, width: pill.width * fraction, height: pill.height)

        ctx.saveGState()
        ctx.addPath(pillPath)
        ctx.clip()
        ctx.setFillColor(ink)
        ctx.fill(pill)
        ctx.setFillColor(lowPowerYellow)
        ctx.fill(filled)
        Content(style).draw(in: ctx, color: CGColor(gray: 0.08, alpha: 1))
        ctx.restoreGState()

        ctx.setFillColor(fraction >= 1 ? lowPowerYellow : ink)
        ctx.addPath(nubPath())
        ctx.fillPath()
    }

    static func nubPath() -> CGPath {
        let r = nub.width
        let path = CGMutablePath()
        path.move(to: CGPoint(x: nub.minX, y: nub.minY))
        path.addLine(to: CGPoint(x: nub.maxX - r, y: nub.minY))
        path.addArc(
            tangent1End: CGPoint(x: nub.maxX, y: nub.minY), tangent2End: CGPoint(x: nub.maxX, y: nub.midY), radius: r)
        path.addArc(
            tangent1End: CGPoint(x: nub.maxX, y: nub.maxY), tangent2End: CGPoint(x: nub.maxX - r, y: nub.maxY),
            radius: r)
        path.addLine(to: CGPoint(x: nub.minX, y: nub.maxY))
        path.closeSubpath()
        return path
    }

    /// Number and bolt laid out centred in the pill.
    private struct Content {
        var line: CTLine?
        var lineWidth: CGFloat = 0
        var capHeight: CGFloat = 0
        var bolt: CGRect?
        var origin: CGFloat = 0

        static let boltSize = CGSize(width: 5.0, height: 8.5)
        static let gap: CGFloat = 1.0

        init(_ style: Style) {
            let available = MenuBarGlyph.pill.width - 2.5
            let boltWidth = style.showsBolt ? Self.boltSize.width : 0
            if let text = style.percentText {
                // Shrink only if needed ("100" + bolt).
                for fontSize in stride(from: CGFloat(10), through: 7.5, by: -0.5) {
                    let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
                    let attributed = NSAttributedString(
                        string: text,
                        attributes: [
                            .font: font,
                            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
                        ])
                    let candidate = CTLineCreateWithAttributedString(attributed)
                    let width = CGFloat(CTLineGetTypographicBounds(candidate, nil, nil, nil))
                    line = candidate
                    lineWidth = width
                    capHeight = font.capHeight
                    if width + (boltWidth > 0 ? Self.gap + boltWidth : 0) <= available { break }
                }
            }
            let total = lineWidth + (boltWidth > 0 ? (line != nil ? Self.gap : 0) + boltWidth : 0)
            origin = MenuBarGlyph.pill.midX - total / 2
            if style.showsBolt {
                let x = origin + total - boltWidth
                bolt = CGRect(
                    x: x, y: MenuBarGlyph.pill.midY - Self.boltSize.height / 2,
                    width: Self.boltSize.width, height: Self.boltSize.height)
            }
        }

        func draw(in ctx: CGContext, color: CGColor = CGColor(gray: 0, alpha: 1)) {
            ctx.setFillColor(color)
            if let line {
                ctx.textMatrix = .identity
                // Optical centre: digits sit on the baseline, so centre their cap height.
                ctx.textPosition = CGPoint(
                    x: origin, y: (MenuBarGlyph.pill.midY - capHeight / 2).rounded(.toNearestOrEven))
                CTLineDraw(line, ctx)
            }
            if let bolt {
                let p = { (x: CGFloat, y: CGFloat) in
                    CGPoint(x: bolt.minX + x * bolt.width, y: bolt.minY + y * bolt.height)
                }
                let path = CGMutablePath()
                path.addLines(between: [
                    p(0.70, 1.00), p(0.04, 0.43), p(0.46, 0.43),
                    p(0.30, 0.00), p(0.96, 0.58), p(0.54, 0.58),
                ])
                path.closeSubpath()
                ctx.addPath(path)
                ctx.fillPath()
            }
        }
    }
}
