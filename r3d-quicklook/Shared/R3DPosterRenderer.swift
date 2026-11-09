import AppKit

/// Draws thumbnails: either a decoded frame, or a "clip card" built from header information.
/// All drawing goes into the *current* NSGraphicsContext with a bottom-left origin, which is what
/// QLThumbnailReply's drawing block provides.
enum R3DPosterRenderer {
    static let accent = NSColor(srgbRed: 0.83, green: 0.06, blue: 0.13, alpha: 1)

    /// Aspect ratio to use for a clip's thumbnail (falls back to 17:9, RED's DCI-ish default).
    static func aspectRatio(for info: R3DClipInfo?) -> CGFloat {
        if let w = info?.width, let h = info?.height, h > 0 {
            return min(max(CGFloat(w) / CGFloat(h), 0.5), 3)
        }
        return 17.0 / 9.0
    }

    /// Largest size with `aspect` that fits in `bounds`.
    static func fit(aspect: CGFloat, in bounds: CGSize) -> CGSize {
        guard bounds.width > 0, bounds.height > 0, aspect > 0 else { return bounds }
        if bounds.width / bounds.height > aspect {
            return CGSize(width: (bounds.height * aspect).rounded(), height: bounds.height)
        }
        return CGSize(width: bounds.width, height: (bounds.width / aspect).rounded())
    }

    static func drawFrame(_ image: CGImage, in rect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NSColor.black.setFill()
        rect.fill()
        let size = fit(aspect: CGFloat(image.width) / CGFloat(max(image.height, 1)), in: rect.size)
        let target = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                            width: size.width, height: size.height)
        context.interpolationQuality = .high
        context.draw(image, in: target)
    }

    static func drawPlaceholder(info: R3DClipInfo?, in rect: CGRect) {
        let gradient = NSGradient(starting: NSColor(white: 0.17, alpha: 1), ending: NSColor(white: 0.04, alpha: 1))
        gradient?.draw(in: rect, angle: -90)

        // Red accent stripe along the bottom edge.
        accent.setFill()
        CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(2, rect.height * 0.04)).fill()

        let unit = min(rect.height, rect.width / 1.8)
        let titleFont = NSFont.systemFont(ofSize: unit * 0.30, weight: .heavy)
        let detailFont = NSFont.monospacedDigitSystemFont(ofSize: max(7, unit * 0.085), weight: .medium)
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        centered.lineBreakMode = .byTruncatingTail

        var lines: [NSAttributedString] = [
            NSAttributedString(string: "R3D", attributes: [
                .font: titleFont,
                .foregroundColor: NSColor.white,
                .kern: unit * 0.012,
                .paragraphStyle: centered,
            ]),
        ]
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: detailFont,
            .foregroundColor: NSColor(white: 0.78, alpha: 1),
            .paragraphStyle: centered,
        ]
        if let info {
            let resolution = [info.resolutionClass, info.resolutionText].compactMap { $0 }.joined(separator: "  ")
            if !resolution.isEmpty { lines.append(NSAttributedString(string: resolution, attributes: detailAttributes)) }
            let timing = [info.frameRateText.map { "\($0) fps" }, info.durationText].compactMap { $0 }.joined(separator: "  ·  ")
            if !timing.isEmpty { lines.append(NSAttributedString(string: timing, attributes: detailAttributes)) }
        }

        let spacing = unit * 0.04
        let heights = lines.map { ceil($0.size().height) }
        let total = heights.reduce(0, +) + spacing * CGFloat(lines.count - 1)
        var y = rect.midY + total / 2
        for (line, height) in zip(lines, heights) {
            y -= height
            line.draw(in: CGRect(x: rect.minX + 4, y: y, width: rect.width - 8, height: height))
            y -= spacing
        }
    }

    /// Renders with `draw` into an offscreen bitmap (used for the placeholder in HTML previews).
    static func makeImage(size: CGSize, scale: CGFloat = 2, draw: (CGRect) -> Void) -> CGImage? {
        let pixelWidth = Int(size.width * scale), pixelHeight = Int(size.height * scale)
        guard pixelWidth > 0, pixelHeight > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        draw(CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    static func placeholderImage(info: R3DClipInfo?, width: CGFloat = 640) -> CGImage? {
        let size = CGSize(width: width, height: (width / aspectRatio(for: info)).rounded())
        return makeImage(size: size) { drawPlaceholder(info: info, in: $0) }
    }
}
