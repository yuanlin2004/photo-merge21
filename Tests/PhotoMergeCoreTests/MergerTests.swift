import XCTest
import CoreGraphics
import ImageIO
import Accelerate
import UniformTypeIdentifiers
@testable import PhotoMergeCore

final class MergerTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func fixture(_ name: String, width: Int, height: Int, pixels: [UInt16], orientation: Int = 1,
                 space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) throws -> Photo {
        let data = pixels.withUnsafeBytes { Data($0) }
        let provider = CGDataProvider(data: data as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64,
                            bytesPerRow: width * 8, space: space,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(.byteOrder16Little),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let url = directory.appendingPathComponent(name + ".tiff")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return try Photo(url: url)
    }
    func values(_ image: CGImage) -> [UInt16] {
        let data = image.dataProvider!.data! as Data
        return data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
    }
    let red: [UInt16] = [65535, 0, 0, 65535]
    let green: [UInt16] = [0, 65535, 0, 65535]
    let blue: [UInt16] = [0, 0, 65535, 65535]

    func testVerticalPixelsAndTransparentPadding() throws {
        let a = try fixture("a", width: 2, height: 1, pixels: red + green)
        let b = try fixture("b", width: 1, height: 1, pixels: blue)
        let image = try Merger.merge(a, b, layout: .vertical)
        XCTAssertEqual(image.width, 2); XCTAssertEqual(image.height, 2)
        XCTAssertEqual(values(image), red + green + blue + [0, 0, 0, 0])
    }
    func testHorizontalTopAlignment() throws {
        let a = try fixture("a", width: 1, height: 2, pixels: red + green)
        let b = try fixture("b", width: 1, height: 1, pixels: blue)
        let image = try Merger.merge(a, b, layout: .horizontal)
        XCTAssertEqual(image.width, 2); XCTAssertEqual(image.height, 2)
        XCTAssertEqual(values(image), red + blue + green + [0, 0, 0, 0])
    }
    func testAllEXIFOrientations() throws {
        let ids: [UInt16] = [1000, 2000, 3000, 4000, 5000, 6000]
        let pixels = ids.flatMap { [$0, $0, $0, UInt16.max] }
        let expected: [[UInt16]] = [
            [1000,2000,3000,4000,5000,6000], [2000,1000,4000,3000,6000,5000],
            [6000,5000,4000,3000,2000,1000], [5000,6000,3000,4000,1000,2000],
            [1000,3000,5000,2000,4000,6000], [5000,3000,1000,6000,4000,2000],
            [6000,4000,2000,5000,3000,1000], [2000,4000,6000,1000,3000,5000]
        ]
        let other = try fixture("other", width: 1, height: 1, pixels: red)
        for orientation in 1...8 {
            let a = try fixture("orientation\(orientation)", width: 2, height: 3, pixels: pixels, orientation: orientation)
            XCTAssertEqual(a.orientation, orientation)
            let image = try Merger.merge(a, other, layout: .vertical)
            let actual = stride(from: 0, to: 24, by: 4).map { values(image)[$0] }
            XCTAssertEqual(actual, expected[orientation - 1], "Orientation \(orientation)")
        }
    }
    func testPNGPreserves16BitAndAlphaAndRefusesOverwrite() throws {
        let pixel: [UInt16] = [12345, 34567, 56789, 32768]
        let a = try fixture("a", width: 1, height: 1, pixels: pixel)
        let image = try Merger.merge(a, a, layout: .horizontal)
        XCTAssertEqual(values(image), pixel + pixel)
        let url = directory.appendingPathComponent("result.png")
        try Merger.save(image, to: url)
        let read = try Photo(url: url)
        XCTAssertEqual(read.image.bitsPerComponent, 16)
        let roundtrip = try Merger.merge(read, a, layout: .horizontal)
        XCTAssertEqual(values(roundtrip), pixel + pixel + pixel)
        XCTAssertThrowsError(try Merger.save(image, to: url))
        try Merger.save(image, to: url, overwrite: true)
        XCTAssertThrowsError(try Merger.save(image, to: directory.appendingPathComponent("bad.jpg")))
    }
    func testMixedProfilesUseWideGamut() throws {
        let a = try fixture("a", width: 1, height: 1, pixels: red)
        let b = try fixture("b", width: 1, height: 1, pixels: green, space: CGColorSpace(name: CGColorSpace.displayP3)!)
        let image = try Merger.merge(a, b, layout: .horizontal)
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.rommrgb)
        XCTAssertEqual(image.bitsPerComponent, 16)
    }
    func testEightBitSamplesArePreserved() throws {
        let samples = (0...255).flatMap { [UInt8($0), UInt8(255 - $0), UInt8($0), UInt8(255)] }
        let image = CGImage(width: 256, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 1024, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: CGDataProvider(data: Data(samples) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)!
        let url = directory.appendingPathComponent("eight.png")
        try Merger.save(image, to: url)
        let photo = try Photo(url: url)
        let merged = try Merger.merge(photo, photo, layout: .vertical)
        let expected = samples.map { UInt16($0) * 257 }
        XCTAssertEqual(values(merged), expected + expected)
    }

    func testCLIEndToEnd() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = root.appendingPathComponent(".build/debug/photo-merge")
        let a = try fixture("first photo", width: 2, height: 1, pixels: red + green)
        let b = try fixture("second photo", width: 1, height: 1, pixels: blue)
        let output = directory.appendingPathComponent("merged photo.png")
        func run(_ args: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = executable
            process.arguments = args
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        XCTAssertEqual(try run(["--layout", "horizontal", a.url.path, b.url.path, "-o", output.path]), 0)
        let merged = try Photo(url: output)
        XCTAssertEqual(merged.width, 3); XCTAssertEqual(merged.height, 1)
        XCTAssertEqual(try run([a.url.path, b.url.path, "-o", output.path]), 1)
        XCTAssertEqual(try run([a.url.path, b.url.path, "-o", output.path, "--overwrite"]), 0)
        XCTAssertEqual(try run([a.url.path, b.url.path, "-o", output.path, "--overwrite"]), 0)
        XCTAssertNotNil(try FlipDocument(url: output).metadata)
        let matched = try Photo(url: output)
        XCTAssertEqual(matched.width, 2); XCTAssertEqual(matched.height, 3)
        XCTAssertEqual(try run(["--match-size", "third", a.url.path, b.url.path, "-o", output.path]), 1)
        XCTAssertEqual(try run(["--layout", "diagonal", a.url.path, b.url.path, "-o", output.path]), 1)
        XCTAssertEqual(try run([a.url.path, b.url.path, "-o", a.url.path, "--overwrite"]), 1)
    }

    func testUnequalPhotosAreCenteredOnBothAxes() throws {
        let wide = try fixture("wide", width: 4, height: 1, pixels: red + red + red + red)
        let small = try fixture("small", width: 1, height: 1, pixels: blue)
        let clear: [UInt16] = [0, 0, 0, 0]
        let vertical = try Merger.merge(wide, small, layout: .vertical)
        // An odd extra pixel goes on the trailing side.
        XCTAssertEqual(Array(values(vertical).suffix(16)), clear + blue + clear + clear)
        let tall = try fixture("tall", width: 1, height: 3, pixels: red + red + red)
        let horizontal = try Merger.merge(small, tall, layout: .horizontal)
        XCTAssertEqual(values(horizontal), clear + red + blue + red + clear + red)
    }

    func testMatchingEitherReferencePreservesProportionsAndPixels() throws {
        let a = try fixture("a", width: 4, height: 2, pixels: Array(repeating: red, count: 8).flatMap { $0 })
        let b = try fixture("b", width: 2, height: 3, pixels: Array(repeating: blue, count: 6).flatMap { $0 })
        for (mode, width, height) in [(SizeMode.first, 4, 8), (.second, 2, 4)] {
            let merged = try Merger.merge(a, b, layout: .vertical, sizeMode: mode)
            XCTAssertEqual(merged.width, width); XCTAssertEqual(merged.height, height)
            let firstHeight = mode == .first ? 2 : 1
            let expected = Array(repeating: red, count: width * firstHeight).flatMap { $0 }
                + Array(repeating: blue, count: width * (height - firstHeight)).flatMap { $0 }
            XCTAssertEqual(values(merged), expected)
        }
        let sizes = Merger.photoSizes(a, b, layout: .horizontal, sizeMode: .second)
        XCTAssertEqual(sizes[0].width, 6); XCTAssertEqual(sizes[0].height, 3)
        let horizontal = try Merger.merge(a, b, layout: .horizontal, sizeMode: .second)
        XCTAssertEqual(horizontal.width, 8); XCTAssertEqual(horizontal.height, 3)
        let row = Array(repeating: red, count: 6).flatMap { $0 } + blue + blue
        XCTAssertEqual(values(horizontal), row + row + row)
        let first = try Merger.merge(a, b, layout: .horizontal, sizeMode: .first)
        XCTAssertEqual(first.width, 5); XCTAssertEqual(first.height, 2)
    }

    func testMatchingUsesOrientedDimensionsAndPreservesAlpha() throws {
        let pixel: [UInt16] = [12345, 34567, 56789, 32768]
        let a = try fixture("a", width: 4, height: 1, pixels: red + red + red + red)
        let b = try fixture("b", width: 1, height: 2, pixels: pixel + pixel, orientation: 6)
        let merged = try Merger.merge(a, b, layout: .vertical, sizeMode: .first)
        XCTAssertEqual(merged.width, 4); XCTAssertEqual(merged.height, 3)
        XCTAssertEqual(Array(values(merged).suffix(32)), Array(repeating: pixel, count: 8).flatMap { $0 })
    }

    func normalizedValues(_ image: CGImage) throws -> [UInt16] {
        var format = vImage_CGImageFormat(bitsPerComponent: 16, bitsPerPixel: 64,
            colorSpace: Unmanaged.passUnretained(image.colorSpace!),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(.byteOrder16Little),
            version: 0, decode: nil, renderingIntent: .defaultIntent)
        var buffer = vImage_Buffer()
        XCTAssertEqual(vImageBuffer_InitWithCGImage(&buffer, &format, nil, image, 0), kvImageNoError)
        defer { free(buffer.data) }
        return (0..<image.height).flatMap { y in
            Array(UnsafeBufferPointer(start: buffer.data.advanced(by: y * buffer.rowBytes).assumingMemoryBound(to: UInt16.self), count: image.width * 4))
        }
    }

    func testMetadataRecoversCenteredPhotosWithoutPadding() throws {
        let a = try fixture("a", width: 4, height: 1, pixels: red + green + blue + red)
        let b = try fixture("b", width: 1, height: 3, pixels: blue + green + red)
        for layout in Layout.allCases {
            let image = try Merger.merge(a, b, layout: layout)
            let metadata = MergeMetadata.make(a, b, layout: layout)
            let url = directory.appendingPathComponent("metadata-\(layout).png")
            try Merger.save(image, to: url, metadata: metadata)
            let document = try FlipDocument(url: url)
            XCTAssertEqual(document.metadata, metadata)
            let recovered = try document.photos()
            XCTAssertEqual(recovered[0].width, 4); XCTAssertEqual(recovered[0].height, 1)
            XCTAssertEqual(recovered[1].width, 1); XCTAssertEqual(recovered[1].height, 3)
            XCTAssertEqual(try normalizedValues(recovered[0]), red + green + blue + red)
            XCTAssertEqual(try normalizedValues(recovered[1]), blue + green + red)
            XCTAssertEqual(try normalizedValues(document.image), values(image))
        }
    }

    func testMetadataRecoversResizedAndOrientedPhotos() throws {
        let a = try fixture("a", width: 4, height: 2, pixels: Array(repeating: red, count: 8).flatMap { $0 })
        let b = try fixture("b", width: 3, height: 2, pixels: Array(repeating: blue, count: 6).flatMap { $0 }, orientation: 6)
        for layout in Layout.allCases {
            for mode in [SizeMode.first, .second] {
                let image = try Merger.merge(a, b, layout: layout, sizeMode: mode)
                let url = directory.appendingPathComponent("\(layout)-\(mode).png")
                let metadata = MergeMetadata.make(a, b, layout: layout, sizeMode: mode)
                try Merger.save(image, to: url, metadata: metadata)
                let recovered = try FlipDocument(url: url).photos()
                let sizes = Merger.photoSizes(a, b, layout: layout, sizeMode: mode)
                for i in 0...1 {
                    XCTAssertEqual(recovered[i].width, sizes[i].width)
                    XCTAssertEqual(recovered[i].height, sizes[i].height)
                    XCTAssertEqual(try normalizedValues(recovered[i]), Array(repeating: i == 0 ? red : blue, count: sizes[i].width * sizes[i].height).flatMap { $0 })
                }
            }
        }
    }

    func testLegacySplitAndInvalidMetadata() throws {
        let a = try fixture("a", width: 2, height: 1, pixels: red + green)
        let image = try Merger.merge(a, a, layout: .vertical)
        let url = directory.appendingPathComponent("legacy.png")
        try Merger.save(image, to: url)
        let legacy = try FlipDocument(url: url)
        XCTAssertNil(legacy.metadata)
        XCTAssertEqual(try normalizedValues(legacy.photos()[0]), red + green)
        XCTAssertEqual(try legacy.photos(legacyLayout: .horizontal)[0].width, 1)
        XCTAssertThrowsError(try legacy.photos(firstShare: .nan))
        let invalid = MergeMetadata(version: 99, layout: "vertical", width: 2, height: 2, photos: [])
        XCTAssertThrowsError(try Merger.save(image, to: url, overwrite: true, metadata: invalid))
        let badBounds = MergeMetadata(version: 1, layout: "vertical", width: 2, height: 2,
            photos: [PhotoRegion(x: Int.max, y: 0, width: 1, height: 1), PhotoRegion(x: 0, y: 1, width: 1, height: 1)])
        XCTAssertThrowsError(try badBounds.validate(width: 2, height: 2))
        let metadata = MergeMetadata.make(a, a, layout: .vertical)
        XCTAssertThrowsError(try metadata.validate(width: 9, height: 9))
        var encoded = try PNGMergeMetadata.adding(metadata, to: Data(contentsOf: url))
        let keyword = encoded.range(of: Data("PhotoMerge".utf8))!
        encoded[keyword.upperBound + 6] ^= 1
        XCTAssertThrowsError(try PNGMergeMetadata.read(from: encoded))
    }

    func testInvalidInputAndInputProtection() throws {
        XCTAssertThrowsError(try Photo(url: directory.appendingPathComponent("missing.png")))
        let a = try fixture("a", width: 1, height: 1, pixels: red)
        XCTAssertThrowsError(try Merger.validateOutput(a.url, inputs: [a.url]))
        let link = directory.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a.url)
        XCTAssertThrowsError(try Merger.validateOutput(link, inputs: [a.url]))
        let hardlink = directory.appendingPathComponent("hardlink.png")
        try FileManager.default.linkItem(at: a.url, to: hardlink)
        XCTAssertThrowsError(try Merger.validateOutput(hardlink, inputs: [a.url]))
    }
}
