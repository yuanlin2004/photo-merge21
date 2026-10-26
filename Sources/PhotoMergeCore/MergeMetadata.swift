import Foundation
import CoreGraphics
import ImageIO

/// Pixel coordinates are measured from the top-left of the merged PNG.
public struct PhotoRegion: Codable, Equatable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

public struct MergeMetadata: Codable, Equatable {
    public let version: Int
    public let layout: String
    public let width: Int
    public let height: Int
    public let photos: [PhotoRegion]

    public static func make(_ a: Photo, _ b: Photo, layout: Layout, sizeMode: SizeMode = .original) -> Self {
        let sizes = Merger.photoSizes(a, b, layout: layout, sizeMode: sizeMode)
        let canvas = Merger.dimensions(a, b, layout: layout, sizeMode: sizeMode)
        let regions = sizes.enumerated().map { index, size in
            PhotoRegion(
                x: layout == .vertical ? (canvas.width - size.width) / 2 : (index == 1 ? sizes[0].width : 0),
                y: layout == .horizontal ? (canvas.height - size.height) / 2 : (index == 1 ? sizes[0].height : 0),
                width: size.width, height: size.height)
        }
        return Self(version: 1, layout: layout.rawValue, width: canvas.width, height: canvas.height, photos: regions)
    }

    public func validate(width actualWidth: Int, height actualHeight: Int) throws {
        guard version == 1, Layout(rawValue: layout) != nil,
              width == actualWidth, height == actualHeight, photos.count == 2 else {
            throw MergeError("The photo-flip metadata does not match this image or uses an unsupported version.")
        }
        for p in photos {
            guard p.x >= 0, p.y >= 0, p.width > 0, p.height > 0,
                  p.width <= width, p.height <= height,
                  p.x <= width - p.width, p.y <= height - p.height else {
                throw MergeError("The photo-flip metadata contains invalid photo boundaries.")
            }
        }
        let a = photos[0], b = photos[1]
        guard layout == Layout.vertical.rawValue ? a.y + a.height <= b.y : a.x + a.width <= b.x else {
            throw MergeError("The photo-flip metadata contains overlapping or reversed photos.")
        }
    }
}

/// Standard PNG iTXt chunk: compatible with other image viewers, no pixel changes.
enum PNGMergeMetadata {
    static let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])
    static let keyword = Data("PhotoMerge".utf8)
    static func crc(_ data: Data) -> UInt32 {
        var result = UInt32.max
        for byte in data {
            result ^= UInt32(byte)
            for _ in 0..<8 { result = (result >> 1) ^ ((result & 1) == 1 ? 0xedb88320 : 0) }
        }
        return result ^ UInt32.max
    }
    static func integer(_ value: UInt32) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }
    static func readInteger(_ data: Data, _ offset: Int) -> Int {
        data[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
    }
    static func adding(_ metadata: MergeMetadata, to png: Data) throws -> Data {
        guard png.starts(with: signature), png.count >= 20 else { throw MergeError("Invalid PNG output.") }
        let json = try JSONEncoder().encode(metadata)
        // keyword NUL, compression flag=0, compression method=0, language NUL, translated keyword NUL.
        let payload = keyword + Data([0, 0, 0, 0, 0]) + json
        let typed = Data("iTXt".utf8) + payload
        let chunk = integer(UInt32(payload.count)) + typed + integer(crc(typed))
        return png.prefix(png.count - 12) + chunk + png.suffix(12)
    }
    static func read(from data: Data) throws -> MergeMetadata? {
        guard data.starts(with: signature) else { return nil }
        var offset = 8
        var found: MergeMetadata?
        while offset <= data.count - 12 {
            let length = readInteger(data, offset)
            guard length <= data.count - offset - 12 else { throw MergeError("The PNG is truncated.") }
            let type = data.subdata(in: offset + 4..<offset + 8)
            if type == Data("iTXt".utf8), length >= keyword.count + 1,
               data.subdata(in: offset + 8..<offset + 8 + keyword.count + 1) == keyword + Data([0]) {
                guard found == nil, length <= 65536,
                      length >= keyword.count + 5,
                      data.subdata(in: offset + 8 + keyword.count..<offset + 8 + keyword.count + 5) == Data([0,0,0,0,0]),
                      crc(data.subdata(in: offset + 4..<offset + 8 + length)) == UInt32(readInteger(data, offset + 8 + length)) else {
                    throw MergeError("The photo-flip metadata is damaged or unsupported.")
                }
                do {
                    found = try JSONDecoder().decode(MergeMetadata.self, from: data.subdata(in: offset + 8 + keyword.count + 5..<offset + 8 + length))
                } catch { throw MergeError("Cannot read the photo-flip metadata.") }
            }
            offset += length + 12
            if type == Data("IEND".utf8) { return found }
        }
        throw MergeError("The PNG is incomplete.")
    }
}

public struct FlipDocument {
    public let image: CGImage
    public let metadata: MergeMetadata?
    public init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let metadata = try PNGMergeMetadata.read(from: data)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 100_000, height <= 100_000,
              Int64(width) * Int64(height) <= 125_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw MergeError("Cannot open this image, or it exceeds the 125-million-pixel limit.")
        }
        try metadata?.validate(width: width, height: height)
        self.image = image
        self.metadata = metadata
    }
    public func photos(legacyLayout: Layout = .vertical, firstShare: Double = 0.5) throws -> [CGImage] {
        let regions: [PhotoRegion]
        if let metadata { regions = metadata.photos }
        else {
            let vertical = legacyLayout == .vertical
            let extent = vertical ? image.height : image.width
            guard extent >= 2, firstShare.isFinite, firstShare > 0, firstShare < 1 else {
                throw MergeError("Choose a valid split with at least one pixel in each photo.")
            }
            let split = max(1, min(extent - 1, Int((Double(extent) * firstShare).rounded())))
            regions = vertical
                ? [PhotoRegion(x: 0, y: 0, width: image.width, height: split),
                   PhotoRegion(x: 0, y: split, width: image.width, height: image.height - split)]
                : [PhotoRegion(x: 0, y: 0, width: split, height: image.height),
                   PhotoRegion(x: split, y: 0, width: image.width - split, height: image.height)]
        }
        return try regions.map {
            guard let crop = image.cropping(to: $0.rect) else { throw MergeError("Cannot extract photo from this image.") }
            return crop
        }
    }
}
