import AppKit
import PhotoMergeCore

let arguments = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
if !arguments.isEmpty {
    do { try CLI.run(arguments) }
    catch {
        FileHandle.standardError.write(Data("photo-merge: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
