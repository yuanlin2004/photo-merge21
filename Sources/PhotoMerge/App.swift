import AppKit
import ImageIO
import UniformTypeIdentifiers
import PhotoMergeCore

final class DropCard: NSView {
    var onFiles: (([URL]) -> Void)?
    var enabled = true
    private let imageView = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "Drop a photo or click to choose")
    private var highlighted = false { didSet { needsDisplay = true } }
    init(number: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        title.stringValue = "Photo \(number)"
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.alignment = .center
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = NSImage(systemSymbolName: "photo.badge.plus", accessibilityDescription: "Choose photo \(number)")
        imageView.contentTintColor = .tertiaryLabelColor
        let stack = NSStackView(views: [imageView, title, detail])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            imageView.heightAnchor.constraint(equalToConstant: 130),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Choose photo \(number)")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
        (highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.10) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (highlighted ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = highlighted ? 2 : 1
        path.stroke()
    }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { choose() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { choose() } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { choose(); return true }
    func choose() {
        guard enabled else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Choose"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK { self?.onFiles?(panel.urls) }
        }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard enabled, !files(sender).isEmpty else { return [] }
        highlighted = true
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        guard enabled else { return false }
        let urls = files(sender)
        guard !urls.isEmpty else { return false }
        onFiles?(urls)
        return true
    }
    private func files(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
    func show(_ photo: Photo) {
        title.stringValue = photo.url.lastPathComponent
        detail.stringValue = "\(photo.width) × \(photo.height) pixels"
        setAccessibilityLabel("\(title.stringValue), \(detail.stringValue). Click to replace.")
        if let source = CGImageSourceCreateWithURL(photo.url as CFURL, nil),
           let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 500
           ] as CFDictionary) {
            imageView.image = NSImage(cgImage: thumbnail, size: .zero)
            imageView.contentTintColor = nil
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var photos: [Photo?] = [nil, nil]
    private let cards = [DropCard(number: 1), DropCard(number: 2)]
    private let layoutControl = NSSegmentedControl(labels: ["Top–bottom", "Left–right"], trackingMode: .selectOne, target: nil, action: nil)
    private let sizeControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizeNote = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(labelWithString: "Choose two photos to get started.")
    private let saveButton = NSButton(title: "Merge & Save…", target: nil, action: nil)
    private let swapButton = NSButton(title: "Swap order", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private var busy = false
    private var sizeMode: SizeMode { SizeMode.allCases[sizeControl.indexOfSelectedItem] }
    private var layout: Layout { layoutControl.selectedSegment == 0 ? .vertical : .horizontal }

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 610),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Photo Merge"
        window.center()
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.edgeInsets = NSEdgeInsets(top: 28, left: 28, bottom: 24, right: 28)
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor)
        ])
        let title = NSTextField(labelWithString: "Two photos. One image.")
        title.font = .systemFont(ofSize: 27, weight: .bold)
        root.addArrangedSubview(title)
        let subtitle = NSTextField(labelWithString: "Lossless PNG · Entirely on your Mac")
        subtitle.textColor = .secondaryLabelColor
        root.addArrangedSubview(subtitle)
        let row = NSStackView(views: cards)
        row.distribution = .fillEqually
        row.spacing = 16
        root.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -56).isActive = true
        for (i, card) in cards.enumerated() { card.onFiles = { [weak self] in self?.load($0, into: i) } }
        layoutControl.selectedSegment = 0
        layoutControl.target = self
        layoutControl.action = #selector(updateStatus)
        swapButton.target = self
        swapButton.action = #selector(swap)
        let controls = NSStackView(views: [layoutControl, swapButton])
        controls.spacing = 16
        root.addArrangedSubview(controls)
        sizeControl.addItems(withTitles: ["Keep original sizes", "Match Photo 1", "Match Photo 2"])
        sizeControl.selectItem(at: 1)
        sizeControl.target = self
        sizeControl.action = #selector(updateStatus)
        sizeControl.setAccessibilityLabel("Photo size matching")
        let sizing = NSStackView(views: [NSTextField(labelWithString: "Photo sizes:"), sizeControl])
        sizing.spacing = 12
        root.addArrangedSubview(sizing)
        let note = sizeNote
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        root.addArrangedSubview(note)
        note.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        status.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        status.textColor = .secondaryLabelColor
        root.addArrangedSubview(status)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(save)
        let footer = NSStackView(views: [saveButton, progress])
        footer.spacing = 12
        root.addArrangedSubview(footer)
        updateStatus()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        busy ? .terminateCancel : .terminateNow
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        load(filenames.map { URL(fileURLWithPath: $0) }, into: photos[0] == nil ? 0 : 1)
        sender.reply(toOpenOrPrint: .success)
    }
    private func makeMenu() {
        let menu = NSMenu()
        let item = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Photo Merge", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Photo Merge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu
        menu.addItem(item)
        let file = NSMenuItem()
        file.submenu = NSMenu(title: "File")
        let choose = NSMenuItem(title: "Choose Photos…", action: #selector(choosePhotos), keyEquivalent: "o")
        choose.target = self
        file.submenu!.addItem(choose)
        let save = NSMenuItem(title: "Merge & Save…", action: #selector(self.save), keyEquivalent: "s")
        save.target = self
        file.submenu!.addItem(save)
        menu.addItem(file)
        let edit = NSMenuItem()
        edit.submenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.submenu!.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        menu.addItem(edit)
        NSApp.mainMenu = menu
    }
    @objc private func choosePhotos() { cards[0].choose() }
    private func load(_ urls: [URL], into index: Int) {
        guard !busy else { return }
        guard (1...2).contains(urls.count) else { showError(MergeError("Choose one or two photos at a time.")); return }
        do {
            let loaded = try urls.map { try Photo(url: $0) }
            if loaded.count == 2 { photos = loaded.map { Optional($0) } }
            else { photos[index] = loaded[0] }
            for i in 0...1 { if let photo = photos[i] { cards[i].show(photo) } }
            updateStatus()
        } catch { showError(error) }
    }
    @objc private func swap() {
        guard !busy, photos.allSatisfy({ $0 != nil }) else { return }
        photos.swapAt(0, 1)
        for i in 0...1 { cards[i].show(photos[i]!) }
        updateStatus()
    }
    @objc private func updateStatus() {
        let ready = photos.allSatisfy { $0 != nil }
        saveButton.isEnabled = ready && !busy
        swapButton.isEnabled = ready && !busy
        layoutControl.isEnabled = !busy
        sizeControl.isEnabled = !busy
        if sizeMode == .original {
            sizeNote.stringValue = "Different sizes are centered with transparent padding. Nothing is cropped or resized."
        } else {
            let edge = layout == .vertical ? "width" : "height"
            let reference = sizeMode == .first ? "1" : "2"
            let other = sizeMode == .first ? "2" : "1"
            sizeNote.stringValue = "Photo \(other) scales to Photo \(reference)’s \(edge), keeping its proportions. Photo \(reference) stays unchanged. Resizing resamples pixels."
        }
        cards.forEach { $0.enabled = !busy }
        if ready && !busy {
            let size = Merger.dimensions(photos[0]!, photos[1]!, layout: layout, sizeMode: sizeMode)
            status.stringValue = "Output: \(size.width) × \(size.height) pixels · 16-bit PNG"
        }
    }
    @objc private func save() {
        guard !busy, let a = photos[0], let b = photos[1] else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Merged.png"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do { try Merger.validateOutput(url, inputs: [a.url, b.url]) }
            catch { self.showError(error); return }
            let layout = self.layout
            let sizeMode = self.sizeMode
            self.busy = true
            self.updateStatus()
            self.status.stringValue = "Merging at full resolution…"
            self.progress.startAnimation(nil)
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try Merger.save(Merger.merge(a, b, layout: layout, sizeMode: sizeMode), to: url, overwrite: true, metadata: .make(a, b, layout: layout, sizeMode: sizeMode)) }
                DispatchQueue.main.async {
                    self.busy = false
                    self.progress.stopAnimation(nil)
                    self.updateStatus()
                    switch result {
                    case .success:
                        self.status.stringValue = "Saved \(url.lastPathComponent)"
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    case .failure(let error): self.showError(error)
                    }
                }
            }
        }
    }
    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
