import XCTest
@testable import PhotoMergeCore

final class FlipGeometryTests: XCTestCase {
    func testEveryProjectedCornerFitsThroughoutBothFlipDirections() {
        for size in [CGSize(width: 900, height: 1400), CGSize(width: 1600, height: 500),
                     CGSize(width: 600, height: 600), CGSize(width: 80, height: 120),
                     CGSize(width: 6000, height: 4000)] {
            let canvas = CGRect(origin: .zero, size: size)
            let card = FlipGeometry.cardRect(in: canvas)
            let distance = FlipGeometry.cameraDistance(cardWidth: card.width)
            for degrees in -90...90 {
                let angle = CGFloat(degrees) * .pi / 180
                for x in [-card.width / 2, card.width / 2] {
                    for y in [-card.height / 2, card.height / 2] {
                        let z = -x * sin(angle)
                        let denominator = 1 - z / distance
                        let projected = CGPoint(x: canvas.midX + x * cos(angle) / denominator,
                                                y: canvas.midY + y / denominator)
                        XCTAssertTrue(canvas.contains(projected), "Clipped at \(degrees)° for \(size)")
                    }
                }
            }
        }
    }
}
