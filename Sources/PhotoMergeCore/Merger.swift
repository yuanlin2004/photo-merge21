import Foundation
import CoreGraphics
import ImageIO
import Accelerate
import UniformTypeIdentifiers

public enum Layout: String, CaseIterable { case vertical, horizontal }
public enum SizeMode: String, CaseIterable {
    case original, first, second
}
public struct MergeError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct Photo {
    public let image: CGImage
    public let orientation: Int
    public let url: URL
    public var width: Int { orientation >= 5 ? image.height : image.width }
    public var height: Int { orientation >= 5 ? image.width : image.height }

    public init(url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1 else {
            throw MergeError("Choose a single-frame image: \(url.lastPathComponent)")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        // Do not silently flatten HDR gain maps or RAW captures into an SDR PNG.
        let type = CGImageSourceGetType(source) as String?
        if let type, let ut = UTType(type), ut.conforms(to: .rawImage) {
            throw MergeError("RAW files must first be developed to a lossless PNG or TIFF.")
        }
        if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil {
            throw MergeError("HDR gain-map photos are not supported. Export an SDR PNG or TIFF first.")
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw MergeError("Cannot decode \(url.lastPathComponent).")
        }
        guard image.bitsPerComponent <= 16, !image.bitmapInfo.contains(.floatComponents) else {
            throw MergeError("Floating-point/HDR images cannot be preserved in this PNG workflow.")
        }
        self.image = image
        self.url = url
        let value = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        self.orientation = (1...8).contains(value) ? value : 1
    }
}

public enum Merger {
    public static func photoSizes(_ a: Photo, _ b: Photo, layout: Layout,
                                  sizeMode: SizeMode = .original) -> [(width: Int, height: Int)] {
        var sizes = [(width: a.width, height: a.height), (width: b.width, height: b.height)]
        guard sizeMode != .original else { return sizes }
        let reference = sizeMode == .first ? 0 : 1
        let other = 1 - reference
        if layout == .vertical {
            let ratio = Double(sizes[reference].width) / Double(sizes[other].width)
            sizes[other] = (sizes[reference].width, max(1, Int(min(1e9, (Double(sizes[other].height) * ratio).rounded()))))
        } else {
            let ratio = Double(sizes[reference].height) / Double(sizes[other].height)
            sizes[other] = (max(1, Int(min(1e9, (Double(sizes[other].width) * ratio).rounded()))), sizes[reference].height)
        }
        return sizes
    }

    public static func dimensions(_ a: Photo, _ b: Photo, layout: Layout,
                                  sizeMode: SizeMode = .original) -> (width: Int, height: Int) {
        let sizes = photoSizes(a, b, layout: layout, sizeMode: sizeMode)
        return layout == .vertical ? (max(sizes[0].width, sizes[1].width), sizes[0].height + sizes[1].height)
                                  : (sizes[0].width + sizes[1].width, max(sizes[0].height, sizes[1].height))
    }

    public static func merge(_ a: Photo, _ b: Photo, layout: Layout,
                             sizeMode: SizeMode = .original) throws -> CGImage {
        let sizes = photoSizes(a, b, layout: layout, sizeMode: sizeMode)
        let size = dimensions(a, b, layout: layout, sizeMode: sizeMode)
        // Bound allocation before decoding and leave room for input buffers.
        guard size.width > 0, size.height > 0,
              size.width <= 100_000, size.height <= 100_000,
              Int64(size.width) * Int64(size.height) <= 125_000_000 else {
            throw MergeError("The combined image is too large (maximum 125 million pixels and 100,000 pixels per side).")
        }
        let firstSpace = a.image.colorSpace
        let secondSpace = b.image.colorSpace
        let space: CGColorSpace
        if let firstSpace, let secondSpace, firstSpace.model == .rgb, CFEqual(firstSpace, secondSpace) {
            space = firstSpace
        } else {
            // ProPhoto RGB contains the common photographic RGB gamuts. 16-bit output
            // keeps conversion precision, including when inputs have different profiles.
            space = CGColorSpace(name: CGColorSpace.rommrgb)!
        }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(.byteOrder16Little)
        let rowBytes = size.width * 8
        var result = Data(count: rowBytes * size.height)
        try result.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
            for (index, photo) in [a, b].enumerated() {
                var format = vImage_CGImageFormat(bitsPerComponent: 16, bitsPerPixel: 64,
                    colorSpace: Unmanaged.passUnretained(space), bitmapInfo: info,
                    version: 0, decode: nil, renderingIntent: .relativeColorimetric)
                var input = vImage_Buffer()
                let error = vImageBuffer_InitWithCGImage(&input, &format, nil, photo.image, vImage_Flags(kvImageNoFlags))
                guard error == kvImageNoError else { throw MergeError("Cannot convert image pixels (vImage \(error)).") }
                defer { free(input.data) }
                let target = sizes[index]
                let xOffset = layout == .vertical ? (size.width - target.width) / 2 : (index == 1 ? sizes[0].width : 0)
                let yOffset = layout == .horizontal ? (size.height - target.height) / 2 : (index == 1 ? sizes[0].height : 0)
                let needsScaling = target.width != photo.width || target.height != photo.height
                if needsScaling {
                    // Orient before scaling. Premultiplied floating-point channels avoid
                    // dark/color fringes around transparent edges during interpolation.
                    var pixels = [Float](repeating: 0, count: photo.width * photo.height * 4)
                    let source = input.data.assumingMemoryBound(to: UInt16.self)
                    for y in 0..<photo.image.height {
                        for x in 0..<photo.image.width {
                            let point = orientedPoint(x: x, y: y, width: photo.image.width,
                                                      height: photo.image.height, orientation: photo.orientation)
                            let src = y * input.rowBytes / 2 + x * 4
                            let dst = (point.y * photo.width + point.x) * 4
                            let alpha = Float(source[src + 3]) / 65535
                            for channel in 0..<3 { pixels[dst + channel] = Float(source[src + channel]) / 65535 * alpha }
                            pixels[dst + 3] = alpha
                        }
                    }
                    var scaled = [Float](repeating: 0, count: target.width * target.height * 4)
                    let error = pixels.withUnsafeMutableBytes { src in
                        scaled.withUnsafeMutableBytes { dst in
                            var source = vImage_Buffer(data: src.baseAddress!, height: vImagePixelCount(photo.height),
                                                       width: vImagePixelCount(photo.width), rowBytes: photo.width * 16)
                            var destination = vImage_Buffer(data: dst.baseAddress!, height: vImagePixelCount(target.height),
                                                            width: vImagePixelCount(target.width), rowBytes: target.width * 16)
                            return vImageScale_ARGBFFFF(&source, &destination, nil, vImage_Flags(kvImageHighQualityResampling))
                        }
                    }
                    guard error == kvImageNoError else { throw MergeError("Cannot resize photo (vImage \(error)).") }
                    let destination = output.baseAddress!.assumingMemoryBound(to: UInt16.self)
                    for y in 0..<target.height {
                        for x in 0..<target.width {
                            let src = (y * target.width + x) * 4
                            let dst = ((y + yOffset) * size.width + x + xOffset) * 4
                            let rawAlpha = scaled[src + 3]
                            let alpha = min(1, max(0, rawAlpha))
                            for channel in 0..<3 {
                                let value = rawAlpha > 0 ? scaled[src + channel] / rawAlpha : 0
                                destination[dst + channel] = UInt16((min(1, max(0, value)) * 65535).rounded())
                            }
                            destination[dst + 3] = UInt16((alpha * 65535).rounded())
                        }
                    }
                } else {
                    // Original-size and reference photos retain their exact pixels.
                    for y in 0..<photo.image.height {
                        for x in 0..<photo.image.width {
                            let point = orientedPoint(x: x, y: y, width: photo.image.width,
                                                      height: photo.image.height, orientation: photo.orientation)
                            let src = input.data.advanced(by: y * input.rowBytes + x * 8)
                            let dst = output.baseAddress!.advanced(by: (point.y + yOffset) * rowBytes + (point.x + xOffset) * 8)
                            dst.copyMemory(from: src, byteCount: 8)
                        }
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: result as CFData),
              let image = CGImage(width: size.width, height: size.height, bitsPerComponent: 16,
                bitsPerPixel: 64, bytesPerRow: rowBytes, space: space, bitmapInfo: info,
                provider: provider, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric) else {
            throw MergeError("Cannot create the merged image.")
        }
        return image
    }

    static func orientedPoint(x: Int, y: Int, width w: Int, height h: Int, orientation: Int) -> (x: Int, y: Int) {
        switch orientation {
        case 2: return (w - 1 - x, y)
        case 3: return (w - 1 - x, h - 1 - y)
        case 4: return (x, h - 1 - y)
        case 5: return (y, x)
        case 6: return (h - 1 - y, x)
        case 7: return (h - 1 - y, w - 1 - x)
        case 8: return (y, w - 1 - x)
        default: return (x, y)
        }
    }

    public static func save(_ image: CGImage, to url: URL, overwrite: Bool = false, metadata: MergeMetadata? = nil) throws {
        guard url.pathExtension.lowercased() == "png" else { throw MergeError("Output must have a .png extension.") }
        try metadata?.validate(width: image.width, height: image.height)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw MergeError("Cannot create PNG output.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MergeError("PNG encoding failed.") }
        let encoded = try metadata.map { try PNGMergeMetadata.adding($0, to: data as Data) } ?? (data as Data)
        if overwrite {
            try encoded.write(to: url, options: .atomic)
        } else {
            // Publish the completed file with an exclusive hard link. This is atomic
            // and cannot clobber a destination created while encoding was running.
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".photo-merge-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try encoded.write(to: temporary, options: .withoutOverwriting)
            try FileManager.default.linkItem(at: temporary, to: url)
        }
    }

    public static func validateOutput(_ url: URL, inputs: [URL]) throws {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        for input in inputs {
            if path == input.resolvingSymlinksInPath().standardizedFileURL.path {
                throw MergeError("The output must not replace an input photo.")
            }
            let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
            if let lhs = try? url.resourceValues(forKeys: keys).fileResourceIdentifier as? NSObject,
               let rhs = try? input.resourceValues(forKeys: keys).fileResourceIdentifier as? NSObject,
               lhs == rhs { throw MergeError("The output must not replace an input photo.") }
        }
    }
}
