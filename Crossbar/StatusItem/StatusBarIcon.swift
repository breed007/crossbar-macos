import Cocoa

/// The menu bar glyph: three network nodes strung along a diagonal "crossbar" —
/// the same mark as the app icon, reading as both a network link and a barbell.
///
/// Drawn programmatically with Core Graphics so it's vector-crisp at any size
/// and needs no asset files. Returned as a *template* image, so the menu bar
/// tints it for light/dark and dims it when the popover is open.
enum StatusBarIcon {
    /// - Parameter alert: when `true`, adds a small corner badge to signal that
    ///   something needs attention (e.g. nothing is currently routing traffic).
    static func image(pointSize: CGFloat = 18, alert: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize),
                            flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: ctx, size: rect.width, alert: alert)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func draw(in ctx: CGContext, size s: CGFloat, alert: Bool) {
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let ink = NSColor.black.cgColor   // template image: only the alpha matters
        ctx.setStrokeColor(ink)
        ctx.setFillColor(ink)

        // Three nodes on a diagonal, bottom-left → top-right. The two end nodes
        // are enlarged (the "weights"); the middle is a smaller hub. The bar
        // connecting them is the crossbar.
        let a = CGPoint(x: s * 0.22, y: s * 0.22)   // bottom-left
        let mid = CGPoint(x: s * 0.50, y: s * 0.50)
        let b = CGPoint(x: s * 0.78, y: s * 0.78)   // top-right

        // Connecting bar.
        ctx.setLineWidth(s * 0.085)
        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.strokePath()

        // Nodes.
        func disc(_ p: CGPoint, _ r: CGFloat) {
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }
        disc(a, s * 0.115)
        disc(b, s * 0.115)
        disc(mid, s * 0.085)

        // Attention badge: a filled dot in the lower-right corner, separated from
        // the mark by a knockout ring so it reads as a distinct status indicator.
        if alert {
            let center = CGPoint(x: s * 0.84, y: s * 0.16)
            let radius = s * 0.16
            let gap = s * 0.05
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: CGRect(x: center.x - radius - gap, y: center.y - radius - gap,
                                       width: 2 * (radius + gap), height: 2 * (radius + gap)))
            ctx.restoreGState()
            ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                       width: 2 * radius, height: 2 * radius))
        }
    }
}
