import AppKit
import CoreGraphics

/// The viewport's decoration, rasterized like the Core Graphics canvas. Core Image's Gaussian shadow is not
/// Core Graphics' shadow: the difference is visible on a light backdrop. The document still composites on the GPU.
@MainActor enum GPUCanvasChrome {
    struct Images {
        let background: CGImage
        let border: CGImage
    }
    private struct Key: Equatable {
        let width: Int
        let height: Int
        let rect: CGRect
        let scale: CGFloat
        let dark: Bool
    }
    private static var cached: (Key, Images)?

    /// Cached across brush strokes and edits; regenerated only when the viewport or its appearance changes.
    static func images(size: CGSize, documentRect: CGRect, scale: CGFloat, appearance: NSAppearance) -> Images? {
        guard size.width.isFinite, size.height.isFinite, scale.isFinite, scale > 0,
              size.width >= 1, size.height >= 1, size.width <= 32768, size.height <= 32768 else { return nil }
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard width * height <= 64_000_000 else { return nil }
        let key = Key(width: width, height: height, rect: documentRect, scale: scale, dark: AppChrome.isDark(appearance))
        if let (previous, images) = cached, previous == key { return images }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let background = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let border = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        for context in [background, border] {
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
        }
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        let rect = documentRect.applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
        background.setFillColor(NSColor(white: AppChrome.canvasGray(appearance), alpha: 1).cgColor)
        background.fill(bounds)
        if rect.intersects(bounds) {
            background.saveGState()
            background.setShadow(offset: CGSize(width: 0, height: 3), blur: 14,
                                 color: NSColor.black.withAlphaComponent(0.35).cgColor)
            background.setFillColor(NSColor(white: 0.26, alpha: 1).cgColor)
            background.fill(rect)
            background.restoreGState()
            background.saveGState()
            background.clip(to: rect.intersection(bounds))
            background.setFillColor(NSColor(white: AppChrome.checkerLow(appearance), alpha: 1).cgColor)
            background.fill(rect)
            let visible = rect.intersection(bounds), tile: CGFloat = 10
            let minX = Int(floor((visible.minX - rect.minX) / tile))
            let maxX = Int(ceil((visible.maxX - rect.minX) / tile))
            let minY = Int(floor((visible.minY - rect.minY) / tile))
            let maxY = Int(ceil((visible.maxY - rect.minY) / tile))
            background.setFillColor(NSColor(white: AppChrome.checkerHigh(appearance), alpha: 1).cgColor)
            for row in minY..<maxY {
                for column in minX..<maxX where (row + column).isMultiple(of: 2) {
                    background.fill(CGRect(x: rect.minX + CGFloat(column) * tile,
                                           y: rect.minY + CGFloat(row) * tile, width: tile, height: tile))
                }
            }
            background.restoreGState()
            border.setStrokeColor(NSColor(white: key.dark ? 1 : 0, alpha: 0.13).cgColor)
            border.setLineWidth(1 / scale)
            border.stroke(rect)
        }
        guard let backgroundImage = background.makeImage(), let borderImage = border.makeImage() else { return nil }
        let images = Images(background: backgroundImage, border: borderImage)
        cached = (key, images)
        return images
    }
}
