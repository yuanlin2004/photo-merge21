import AppKit
import QuartzCore
import PhotoMergeCore

final class FlipView: NSView {
    private let stage = CALayer()
    private let card = CALayer()
    private var images: [CGImage] = []
    private var index = 0
    private var animating = false
    private var generation = 0
    var onChange: ((Int) -> Void)?
    var onDrop: ((URL) -> Void)?
    var onLegacyKey: ((UInt16) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer!.backgroundColor = NSColor.clear.cgColor
        card.contentsGravity = .resizeAspect
        card.isDoubleSided = false
        // AppKit's backing layer may anchor at a corner. A centered stage keeps
        // the perspective vanishing point at the photo's center.
        layer!.addSublayer(stage)
        stage.addSublayer(card)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Photo viewer. Click or press Space to flip horizontally.")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.frame = bounds
        let rect = FlipGeometry.cardRect(in: stage.bounds)
        // Do not assign frame while a 3D transform is active: frame is derived
        // from that transform and can distort the card during layout callbacks.
        card.bounds = CGRect(origin: .zero, size: rect.size)
        card.position = CGPoint(x: rect.midX, y: rect.midY)
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / FlipGeometry.cameraDistance(cardWidth: rect.width)
        stage.sublayerTransform = perspective
        CATransaction.commit()
    }
    func show(_ images: [CGImage]) {
        generation += 1
        animating = false
        card.removeAllAnimations()
        self.images = images
        index = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.transform = CATransform3DIdentity
        card.contents = images.first
        CATransaction.commit()
        onChange?(0)
        window?.makeFirstResponder(self)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.modifierFlags.contains(.option) { window?.performDrag(with: event) }
        else { flip() }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 {
            if !event.isARepeat { flip() }
        } else if event.keyCode == 53 {
            NSApp.terminate(nil)
        } else if [4, 9, 123, 124].contains(event.keyCode) {
            onLegacyKey?(event.keyCode)
        } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { flip(); return true }
    func flip() {
        guard images.count == 2, !animating else { return }
        animating = true
        let token = generation
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.10 : 0.24
        // Rotate around the vertical axis regardless of the original merge layout.
        // Exchange textures edge-on, then open the new face without mirroring it.
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.generation == token else { return }
            self.index = 1 - self.index
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.card.contents = self.images[self.index]
            self.card.transform = CATransform3DMakeRotation(-.pi / 2, 0, 1, 0)
            CATransaction.commit()
            self.onChange?(self.index)
            CATransaction.begin()
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, self.generation == token else { return }
                self.animating = false
            }
            self.card.transform = CATransform3DIdentity
            CATransaction.commit()
        }
        card.transform = CATransform3DMakeRotation(.pi / 2, 0, 1, 0)
        CATransaction.commit()
    }
    private func files(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { files(sender).count == 1 ? .copy : [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = files(sender)
        guard urls.count == 1 else { return false }
        onDrop?(urls[0])
        return true
    }
}

// Borderless windows must explicitly opt into keyboard focus.
final class PhotoWindow: NSWindow {
    var onOpen: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "o": onOpen?(); return true
            case "q", "w": NSApp.terminate(nil); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class FlipAppDelegate: NSObject, NSApplicationDelegate {
    private var window: PhotoWindow!
    private let viewer = FlipView(frame: .zero)
    private var document: FlipDocument?
    private var pendingURL: URL?
    private var loadingGeneration = 0
    private var legacyLayout = Layout.vertical
    private var firstShare = 0.5
    private var choosing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = PhotoWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "Photo Flip"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = false
        window.contentView = viewer
        window.center()
        window.onOpen = { [weak self] in self?.choose() }
        viewer.onChange = { [weak self] index in
            self?.viewer.setAccessibilityValue("Photo \(index + 1) of 2")
        }
        viewer.onDrop = { [weak self] in self?.load($0) }
        viewer.onLegacyKey = { [weak self] in self?.changeLegacySplit($0) }
        NSApp.mainMenu = nil
        NSApp.activate(ignoringOtherApps: true)
        let argument = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-psn_") }
        if let url = pendingURL ?? argument.map({ URL(fileURLWithPath: $0) }) { load(url) }
        else { choose() }
    }
    // The initial file picker closes before asynchronous decoding shows the viewer.
    // Do not interpret that temporary absence of windows as a request to quit.
    // Escape/Command-Q/Command-W and cancelling the initial picker exit explicitly.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { choose() }
        return true
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let path = filenames.first {
            let url = URL(fileURLWithPath: path)
            if window == nil { pendingURL = url } else { load(url) }
        }
        sender.reply(toOpenOrPrint: .success)
    }
    private func choose() {
        guard !choosing else { return }
        choosing = true
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard let self else { return }
            self.choosing = false
            if response == .OK, let url = panel.url { self.load(url) }
            else if self.document == nil { NSApp.terminate(nil) }
            else { self.window.makeKeyAndOrderFront(nil); self.window.makeFirstResponder(self.viewer) }
        }
    }
    private func show(_ photos: [CGImage]) {
        // Fit both faces into a stable transparent canvas; no frame or padding is drawn.
        let screen = window.screen ?? NSScreen.main
        let available = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let width = CGFloat(photos.map(\.width).max() ?? 800)
        let height = CGFloat(photos.map(\.height).max() ?? 600)
        let canvasWidth = width * FlipGeometry.canvasScale
        let canvasHeight = height * FlipGeometry.canvasScale
        let scale = min(1, min(available.width * 0.95 / canvasWidth, available.height * 0.95 / canvasHeight))
        window.setContentSize(NSSize(width: max(1, canvasWidth * scale), height: max(1, canvasHeight * scale)))
        window.center()
        viewer.show(photos)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(viewer)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func load(_ url: URL) {
        loadingGeneration += 1
        let token = loadingGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try FlipDocument(url: url) }
            DispatchQueue.main.async {
                guard self.loadingGeneration == token else { return }
                do {
                    let document = try result.get()
                    let photos = try document.photos()
                    self.document = document
                    self.legacyLayout = .vertical
                    self.firstShare = 0.5
                    self.show(photos)
                } catch { self.showError(error) }
            }
        }
    }
    private func changeLegacySplit(_ key: UInt16) {
        guard let document, document.metadata == nil else { return }
        switch key {
        case 4: legacyLayout = .horizontal // H
        case 9: legacyLayout = .vertical   // V
        case 123: firstShare = max(0.01, firstShare - 0.01)
        case 124: firstShare = min(0.99, firstShare + 0.01)
        default: return
        }
        do { show(try document.photos(legacyLayout: legacyLayout, firstShare: firstShare)) }
        catch { showError(error) }
    }
    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
        if document == nil { choose() }
        else { window.makeKeyAndOrderFront(nil); window.makeFirstResponder(viewer) }
    }
}

if CommandLine.arguments.contains("--help") {
    print("""
    Usage: photo-flip [MERGED.png]
    Image-only borderless viewer. Space/click: flip. Escape or Command-Q: quit.
    Command-O: open another PNG. Option-drag: move the image.
    Legacy images: H/V selects layout; Left/Right adjusts the first photo's share.
    """)
} else {
    let app = NSApplication.shared
    let delegate = FlipAppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
