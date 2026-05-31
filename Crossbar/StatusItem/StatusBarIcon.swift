import Cocoa

/// The menu bar glyph: a globe with a diagonal "crossbar" (a barbell) in front.
///
/// Drawn programmatically with Core Graphics so it's vector-crisp at any size
/// and needs no asset files. Returned as a *template* image, so the menu bar
/// tints it for light/dark and dims it when the popover is open — which is also
/// why the bar can't be a literally "brighter" color here (template images are
/// single-channel). Instead the bar reads as in-front via two cues:
///
///   1. A **knockout halo** — the globe's strokes are cleared in a band around
///      the bar, so the bar visually overlaps (sits on top of) the globe.
///   2. The bar is a **barbell** (round weighted end-knobs, inset so it stops
///      short of the corners), so it reads as a physical object rather than the
///      corner-to-corner slash of a "prohibited" globe.
enum StatusBarIcon {
    /// - Parameter alert: when `true`, adds a small corner badge to signal that
    ///   something needs attention (e.g. a service is disabled).
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

        let c = CGPoint(x: s / 2, y: s / 2)
        let r = s * 0.40

        // --- Globe: outline + meridian (vertical ellipse) + equator ---
        ctx.setLineWidth(s * 0.07)
        ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))

        ctx.setLineWidth(s * 0.045)
        let mx = r * 0.46
        ctx.strokeEllipse(in: CGRect(x: c.x - mx, y: c.y - r, width: 2 * mx, height: 2 * r))
        ctx.move(to: CGPoint(x: c.x - r, y: c.y))
        ctx.addLine(to: CGPoint(x: c.x + r, y: c.y))
        ctx.strokePath()

        // --- Crossbar: diagonal barbell with round end-knobs ---
        let a = CGPoint(x: s * 0.21, y: s * 0.31)
        let b = CGPoint(x: s * 0.79, y: s * 0.69)

        // Knockout halo: clear the globe strokes in a band around the bar (and
        // under the knobs) so the bar sits clearly in front.
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.setLineWidth(s * 0.30)
        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.strokePath()
        let haloKnob = s * 0.115
        ctx.fillEllipse(in: CGRect(x: a.x - haloKnob, y: a.y - haloKnob, width: 2 * haloKnob, height: 2 * haloKnob))
        ctx.fillEllipse(in: CGRect(x: b.x - haloKnob, y: b.y - haloKnob, width: 2 * haloKnob, height: 2 * haloKnob))
        ctx.restoreGState()

        // Handle.
        ctx.setLineWidth(s * 0.11)
        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.strokePath()

        // Weighted end-knobs.
        let knob = s * 0.075
        ctx.fillEllipse(in: CGRect(x: a.x - knob, y: a.y - knob, width: 2 * knob, height: 2 * knob))
        ctx.fillEllipse(in: CGRect(x: b.x - knob, y: b.y - knob, width: 2 * knob, height: 2 * knob))

        // Attention badge: a filled dot in the lower-right corner (kept clear of
        // the upper-right crossbar knob), separated from the globe by a knockout
        // ring so it reads as a distinct status indicator.
        if alert {
            let center = CGPoint(x: s * 0.82, y: s * 0.18)
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
