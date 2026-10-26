import CoreGraphics

/// Reserve transparent space for the largest possible perspective projection.
public enum FlipGeometry {
    // Camera distance >= 1.5 * card width gives |z|/distance <= 1/3,
    // so projected coordinates grow by at most 1.5. Leave extra raster clearance.
    public static let canvasScale: CGFloat = 1.6

    public static func cardRect(in canvas: CGRect) -> CGRect {
        let size = CGSize(width: canvas.width / canvasScale, height: canvas.height / canvasScale)
        return CGRect(x: canvas.midX - size.width / 2, y: canvas.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    public static func cameraDistance(cardWidth: CGFloat) -> CGFloat {
        max(800, cardWidth * 1.5)
    }
}
