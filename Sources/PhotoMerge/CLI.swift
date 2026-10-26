import Foundation
import PhotoMergeCore

enum CLI {
    static let help = """
    Photo Merge — join two photos with lossless PNG output.

    Usage: photo-merge [--layout vertical|horizontal] INPUT1 INPUT2 -o OUTPUT.png [--overwrite]
           photo-merge                   Open the desktop app

    Options:
      --layout, -l   vertical (top-down, default) or horizontal (left-right)
      --match-size   original, first (default), or second; match width vertically or height horizontally
      --output, -o   Destination PNG file
      --overwrite    Replace an existing output (never an input)
      --help, -h     Show this help
      --version      Show version
      --             Treat remaining arguments as input paths

    First photo goes on top or left. Unequal sizes are padded transparently,
    centered on the other axis. Matching sizes resamples only the other photo,
    preserving its aspect ratio. Output is a lossless, color-managed 16-bit PNG.
    """
    static func run(_ args: [String]) throws {
        if args.contains("--help") || args.contains("-h") { print(help); return }
        if args == ["--version"] { print("Photo Merge 1.0.0"); return }
        var layout = Layout.vertical
        var sizeMode = SizeMode.first
        var output: String?
        var inputs: [String] = []
        var overwrite = false
        var positional = false
        var i = 0
        while i < args.count {
            let arg = args[i]
            if positional { inputs.append(arg); i += 1; continue }
            switch arg {
            case "--": positional = true
            case "--overwrite": overwrite = true
            case "--layout", "-l", "--output", "-o", "--match-size":
                i += 1
                guard i < args.count else { throw MergeError("Missing value for \(arg).") }
                if arg == "--layout" || arg == "-l" {
                    guard let value = Layout(rawValue: args[i]) else { throw MergeError("Layout must be vertical or horizontal.") }
                    layout = value
                } else if arg == "--match-size" {
                    guard let value = SizeMode(rawValue: args[i]) else { throw MergeError("Match size must be original, first, or second.") }
                    sizeMode = value
                } else { output = args[i] }
            default:
                guard !arg.hasPrefix("-") else { throw MergeError("Unknown option: \(arg). Use --help for usage.") }
                inputs.append(arg)
            }
            i += 1
        }
        guard inputs.count == 2, let output else { throw MergeError("Provide exactly two input photos and -o OUTPUT.png. Use --help for usage.") }
        let urls = inputs.map { URL(fileURLWithPath: $0) }
        let destination = URL(fileURLWithPath: output)
        try Merger.validateOutput(destination, inputs: urls)
        if !overwrite && FileManager.default.fileExists(atPath: destination.path) {
            throw MergeError("Output already exists. Use --overwrite to replace it.")
        }
        let first = try Photo(url: urls[0])
        let second = try Photo(url: urls[1])
        let image = try Merger.merge(first, second, layout: layout, sizeMode: sizeMode)
        try Merger.save(image, to: destination, overwrite: overwrite, metadata: .make(first, second, layout: layout, sizeMode: sizeMode))
        print("Saved \(image.width) × \(image.height) → \(destination.path)")
    }
}
