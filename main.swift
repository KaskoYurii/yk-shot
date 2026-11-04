import AppKit
import Carbon
import CoreImage
import UniformTypeIdentifiers

enum Tool: Int { case pen, rect, arrow, text, blur, focus }

struct Mark {
    let tool: Tool
    var points: [CGPoint]   // pen: path, rect/arrow/blur/focus: [start, end], text: [origin]
    let color: NSColor
    var text = ""
}

func blur(_ cg: CGImage, sigma: Double) -> CGImage? {
    let extent = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
    let ci = CIImage(cgImage: cg).clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
    return CIContext().createCGImage(ci, from: extent)
}

/// Screenshot of the screen the frontmost app is on: that app's windows sharp, everything else blurred.
enum AppCapture {
    static func run() -> NSImage? {
        usleep(250_000)   // let our own editor window disappear first
        guard let (pid, front) = PageCapture.topWindow() else { return nil }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = list.compactMap { w -> CGRect? in
            guard w[kCGWindowOwnerPID as String] as? Int == Int(pid), w[kCGWindowLayer as String] as? Int == 0,
                  let b = w[kCGWindowBounds as String] as? [String: Any] else { return nil }
            return CGRect(dictionaryRepresentation: b as CFDictionary)
        }
        // The screen holding the app's front window, in the same top-left coordinates as window bounds.
        let mainHeight = NSScreen.screens[0].frame.height
        let screens = NSScreen.screens.map { CGRect(x: $0.frame.minX, y: mainHeight - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
        let screen = screens.first { $0.contains(CGPoint(x: front.midX, y: front.midY)) } ?? screens[0]
        guard let sharp = PageCapture.grab(screen), let soft = blur(sharp, sigma: 12 * Double(sharp.width) / screen.width),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: sharp.width, pixelsHigh: sharp.height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = screen.size
        let all = NSRect(origin: .zero, size: screen.size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSImage(cgImage: soft, size: screen.size).draw(in: all)
        // ponytail: plain rounded-rect clip per window; another app's window floating over this one stays sharp there.
        let clip = NSBezierPath()
        for w in windows {
            clip.append(NSBezierPath(roundedRect: NSRect(x: w.minX - screen.minX, y: screen.maxY - w.maxY, width: w.width, height: w.height),
                                     xRadius: 10, yRadius: 10))
        }
        clip.addClip()
        NSImage(cgImage: sharp, size: screen.size).draw(in: all)
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: screen.size)
        out.addRepresentation(rep)
        return out
    }
}

final class Canvas: NSView {
    var image: NSImage? {
        didSet { marks = []; blurCache = nil; setFrameSize(image?.size ?? .zero) }
    }
    var marks: [Mark] = [] { didSet { needsDisplay = true } }
    var current: Mark? { didSet { needsDisplay = true } }
    var tool = Tool.pen
    var color = NSColor.systemRed

    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: bounds)
        let all = marks + [current].compactMap { $0 }
        // Blur/Focus repaint parts of the screenshot itself, so they go under the other marks.
        for m in all where m.tool == .blur || m.tool == .focus { drawBlur(m) }
        for m in all where m.tool != .blur && m.tool != .focus { draw(m) }
    }

    private func box(_ m: Mark) -> NSRect {
        let a = m.points[0], b = m.points.last!
        return NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// Blur: blurs inside the box (hide emails, tokens). Focus: blurs and dims everything outside it.
    private func drawBlur(_ m: Mark) {
        guard let blurred else { return }
        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(rect: box(m))
        if m.tool == .focus { clip.append(NSBezierPath(rect: bounds)); clip.windingRule = .evenOdd }
        clip.addClip()
        blurred.draw(in: bounds)
        if m.tool == .focus { NSColor.black.withAlphaComponent(0.25).setFill(); bounds.fill() }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Blurred copy of the whole screenshot, made once on first use.
    private var blurCache: NSImage?
    private var blurred: NSImage? {
        if blurCache == nil, let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            if let out = blur(cg, sigma: 10 * Double(cg.width) / image.size.width) { blurCache = NSImage(cgImage: out, size: image.size) }
        }
        return blurCache
    }

    private func draw(_ m: Mark) {
        let a = m.points[0], b = m.points.last!
        if m.tool == .text {
            (m.text as NSString).draw(at: a, withAttributes: [.font: NSFont.boldSystemFont(ofSize: 20), .foregroundColor: m.color])
            return
        }
        let p = NSBezierPath()
        p.lineWidth = 3; p.lineCapStyle = .round; p.lineJoinStyle = .round
        switch m.tool {
        case .pen:
            p.move(to: a); m.points.forEach { p.line(to: $0) }
        case .rect:
            p.appendRect(box(m))
        case .arrow:
            p.move(to: a); p.line(to: b)
            let angle = atan2(b.y - a.y, b.x - a.x)
            for d in [0.5, -0.5] {
                p.move(to: b); p.line(to: CGPoint(x: b.x - 16 * cos(angle + d), y: b.y - 16 * sin(angle + d)))
            }
        case .text, .blur, .focus: break
        }
        m.color.setStroke(); p.stroke()
    }

    override func mouseDown(with e: NSEvent) {
        guard image != nil else { return }
        let p = convert(e.locationInWindow, from: nil)
        switch tool {
        case .text:
            if let s = askText(), !s.isEmpty { marks.append(Mark(tool: .text, points: [p], color: color, text: s)) }
        case .pen: current = Mark(tool: tool, points: [p], color: color)
        default: current = Mark(tool: tool, points: [p, p], color: color)
        }
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if tool == .pen { current?.points.append(p) } else { current?.points[1] = p }
    }

    override func mouseUp(with e: NSEvent) {
        if let c = current { marks.append(c) }
        current = nil
    }

    private func askText() -> String? {
        let alert = NSAlert()
        alert.messageText = "Add comment"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Add"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// Screenshot + marks flattened to PNG at full (Retina) resolution.
    func png() -> Data? {
        guard image != nil, let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}

/// Gray backdrop behind the screenshot, like Preview: pads it and gives it a soft shadow.
final class Stage: NSView {
    static let pad = 32.0
    let canvas: Canvas
    init(_ canvas: Canvas) { self.canvas = canvas; super.init(frame: .zero); addSubview(canvas) }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }   // tall pages start at the top

    func fit() {
        canvas.setFrameOrigin(NSPoint(x: Stage.pad, y: Stage.pad))
        setFrameSize(NSSize(width: canvas.frame.width + 2 * Stage.pad, height: canvas.frame.height + 2 * Stage.pad))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.25); shadow.shadowBlurRadius = 16; shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        NSColor.white.setFill(); canvas.frame.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Keeps a screenshot smaller than the window centred instead of stuck in a corner.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposed)
        guard let doc = documentView?.frame else { return r }
        if r.width > doc.width { r.origin.x = (doc.width - r.width) / 2 }
        if r.height > doc.height { r.origin.y = (doc.height - r.height) / 2 }
        return r
    }
}

extension NSToolbarItem.Identifier {
    static let capture = Self("capture"), tools = Self("tools"), color = Self("color")
    static let undo = Self("undo"), copy = Self("copy"), save = Self("save")
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate, NSToolbarDelegate {
    let canvas = Canvas()
    lazy var stage = Stage(canvas)
    let scroll = NSScrollView()
    lazy var toolPicker: NSSegmentedControl = {
        let tools = [("Pen", "pencil.tip"), ("Box", "rectangle"), ("Arrow", "arrow.up.right"),
                     ("Text", "textformat"), ("Blur", "eye.slash"), ("Focus", "scope")]
        let c = NSSegmentedControl(images: tools.map { NSImage(systemSymbolName: $0.1, accessibilityDescription: $0.0) ?? NSImage() },
                                   trackingMode: .selectOne, target: self, action: #selector(pickTool))
        for (i, t) in tools.enumerated() { c.setToolTip(t.0, forSegment: i) }
        c.selectedSegment = 0
        return c
    }()
    let colors: [(String, NSColor)] = [("Red", .systemRed), ("Orange", .systemOrange), ("Yellow", .systemYellow),
                                        ("Green", .systemGreen), ("Blue", .systemBlue), ("Purple", .systemPurple),
                                        ("Black", .black), ("White", .white)]
    lazy var colorPicker: NSPopUpButton = {
        let p = NSPopUpButton(frame: .zero, pullsDown: true)
        p.bezelStyle = .texturedRounded   // .toolbar would tint the colour dot gray
        p.addItem(withTitle: "")   // the button face: a dot in the current colour
        p.lastItem?.image = swatch(canvas.color)
        for (name, c) in colors {
            p.addItem(withTitle: name)
            p.lastItem?.image = swatch(c, size: 14); p.lastItem?.representedObject = c
            p.lastItem?.target = self; p.lastItem?.action = #selector(pickColor)
        }
        p.toolTip = "Colour"
        return p
    }()

    /// Colour dot for the toolbar and its menu, like Markup's colour picker.
    func swatch(_ c: NSColor, size: Double = 16) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            let dot = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
            c.setFill(); dot.fill()
            NSColor.separatorColor.setStroke(); dot.lineWidth = 1; dot.stroke()
            return true
        }
    }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
    let tray = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var hotKeys: [EventHotKeyRef?] = [nil, nil, nil]
    var running: Process?
    var pageBusy = false
    var menuTap: CFMachPort?
    var tapFired = false
    var ignoreHotKeysUntil = Date.distantPast

    /// Menu-bar version of the app icon (viewfinder corners + "YK"). Template = follows light/dark menu bars.
    private func trayIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { r in
            let p = NSBezierPath()
            p.lineWidth = 1.6; p.lineCapStyle = .round; p.lineJoinStyle = .round
            let (x0, y0, x1, y1, arm) = (1.5, 1.5, r.width - 1.5, r.height - 1.5, 4.5)
            for (x, y, dx, dy) in [(x0, y1, 1.0, -1.0), (x1, y1, -1, -1), (x0, y0, 1, 1), (x1, y0, -1, 1)] {
                p.move(to: NSPoint(x: x, y: y + dy * arm)); p.line(to: NSPoint(x: x, y: y)); p.line(to: NSPoint(x: x + dx * arm, y: y))
            }
            NSColor.black.setStroke(); p.stroke()
            let t = NSAttributedString(string: "YK", attributes: [.font: NSFont.systemFont(ofSize: 8, weight: .black), .foregroundColor: NSColor.black])
            let s = t.size()
            t.draw(at: NSPoint(x: (r.width - s.width) / 2, y: (r.height - s.height) / 2))
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "YKShot"
        return img
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        tray.button?.image = trayIcon()
        tray.button?.toolTip = "YKShot"
        tray.menu = menu()
        tray.menu?.delegate = self
        registerHotKey()

        let toolbar = NSToolbar(identifier: "editor")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        scroll.contentView = CenteringClipView()
        scroll.documentView = stage
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.backgroundColor = .underPageBackgroundColor
        scroll.allowsMagnification = true; scroll.minMagnification = 0.1; scroll.maxMagnification = 8   // pinch to zoom

        window.contentView = scroll
        window.title = "YKShot"
        window.contentMinSize = NSSize(width: 760, height: 300)   // whole toolbar fits
        window.isReleasedWhenClosed = false   // closing the editor just hides it; app keeps living in the tray
        // Hidden main menu: no menu bar shows for a tray app, but it still routes ⌘Z/⌘C/⌘S/⌘Q.
        let main = NSMenu(), appItem = NSMenuItem()
        appItem.submenu = menu(); main.addItem(appItem)
        NSApp.mainMenu = main
    }

    private func captureMenu() -> NSMenu {
        let m = NSMenu()
        let items: [(String, Selector, NSEvent.ModifierFlags)] = [
            ("Capture Area", #selector(capture), [.command]),
            ("Capture Full Page", #selector(capturePage), [.command, .shift]),
            ("Capture App, Blur the Rest", #selector(captureApp), [.command, .option]),
        ]
        for (title, sel, mods) in items {
            let item = m.addItem(withTitle: title, action: sel, keyEquivalent: "9")
            item.keyEquivalentModifierMask = mods
            item.target = self
        }
        return m
    }

    private func menu() -> NSMenu {
        let m = captureMenu()
        m.addItem(.separator())
        for (title, sel, key) in [("Undo", #selector(undoMark), "z"), ("Copy", #selector(copyImage), "c"), ("Save…", #selector(saveImage), "s")] {
            m.addItem(withTitle: title, action: sel, keyEquivalent: key).target = self
        }
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Quit YKShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return m
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.capture, .flexibleSpace, .tools, .color, .flexibleSpace, .undo, .copy, .save]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar _: Bool) -> NSToolbarItem? {
        func button(_ label: String, _ symbol: String, _ action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = label; item.toolTip = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.target = self; item.action = action; item.isBordered = true
            item.visibilityPriority = .user   // actions never fall into the » overflow menu
            return item
        }
        func wrap(_ label: String, _ view: NSView) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = label; item.view = view
            return item
        }
        switch id {
        case .capture:   // click = area capture, arrow = the other capture modes
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "Capture"; item.toolTip = "Capture Area (⌘9)"
            item.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Capture")
            item.target = self; item.action = #selector(capture)
            item.menu = captureMenu()
            return item
        case .tools: return wrap("Tools", toolPicker)
        case .color: return wrap("Colour", colorPicker)
        case .undo: return button("Undo (⌘Z)", "arrow.uturn.backward", #selector(undoMark))
        case .copy: return button("Copy (⌘C)", "doc.on.doc", #selector(copyImage))
        case .save: return button("Save (⌘S)", "square.and.arrow.down", #selector(saveImage))
        default: return nil
        }
    }

    // Global ⌘9 (region), ⇧⌘9 (full page) and ⌥⌘9 (app, rest blurred) via Carbon hotkeys: work from any app, need no Accessibility permission.
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var key = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            (NSApp.delegate as? App)?.hotKey(key.id)
            return noErr
        }, 1, &spec, nil, nil)
        for (i, mods) in [cmdKey, cmdKey | shiftKey, cmdKey | optionKey].enumerated() {
            let status = RegisterEventHotKey(UInt32(kVK_ANSI_9), UInt32(mods), EventHotKeyID(signature: 0x5353_4854, id: UInt32(i + 1)),
                                             GetApplicationEventTarget(), 0, &hotKeys[i])
            if status != noErr { NSLog("hotkey \(i + 1) unavailable (status \(status)), use the tray menu") }
        }
    }

    func hotKey(_ id: UInt32) {
        if Date() < ignoreHotKeysUntil { return }
        switch id { case 2: capturePage(); case 3: captureApp(); default: capture() }
    }

    // While our own tray menu is open, macOS holds our shortcuts back until it closes, so the menu could never be
    // captured. A keyboard tap (needs Accessibility) catches ⌘9 / ⇧⌘9 / ⌥⌘9 meanwhile and leaves the menu open.
    func menuWillOpen(_ menu: NSMenu) {
        tapFired = false
        menuTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                    eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                                    callback: { _, _, event, _ in
            let flags = event.flags
            guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_9), flags.contains(.maskCommand),
                  let app = NSApp.delegate as? App else { return Unmanaged.passUnretained(event) }
            app.tapFired = true
            app.hotKey(flags.contains(.maskShift) ? 2 : flags.contains(.maskAlternate) ? 3 : 1)
            return nil   // swallow it so the menu stays open
        }, userInfo: nil)
        if let tap = menuTap { CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes) }
    }

    func menuDidClose(_ menu: NSMenu) {
        if let tap = menuTap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        menuTap = nil
        // macOS may still deliver the held-back shortcut once the menu closes: don't start a second capture.
        if tapFired { ignoreHotKeysUntil = Date().addingTimeInterval(0.5) }
    }

    // Scrolls the topmost window (e.g. your browser) and stitches it. Sending scroll events needs Accessibility.
    @objc func capturePage() {
        guard permitted(accessibility: true) else { return }
        inBackground(PageCapture.run)
    }

    // Whole screen with the frontmost app sharp and everything else blurred.
    @objc func captureApp() {
        guard permitted(accessibility: false) else { return }
        inBackground(AppCapture.run)
    }

    private func inBackground(_ work: @escaping () -> NSImage?) {
        if pageBusy || running?.isRunning == true { return }
        pageBusy = true
        let wasVisible = window.isVisible
        window.orderOut(nil)
        DispatchQueue.global().async {
            let img = work()
            DispatchQueue.main.async { self.pageBusy = false; self.show(img, reopen: wasVisible) }
        }
    }

    /// Says which permission is missing instead of failing silently.
    private func permitted(accessibility: Bool) -> Bool {
        var missing: [(name: String, pane: String)] = []
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()   // adds YKShot to the list in Settings
            missing.append(("Screen & System Audio Recording", "Privacy_ScreenCapture"))
        }
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if accessibility && !AXIsProcessTrustedWithOptions(prompt) {
            missing.append(("Accessibility", "Privacy_Accessibility"))
        }
        guard let first = missing.first else { return true }
        NSLog("YKShot: missing permission: \(missing.map(\.name))")
        let alert = NSAlert()
        alert.messageText = "YKShot needs permission"
        alert.informativeText = "Turn on YKShot in System Settings → Privacy & Security → \(missing.map(\.name).joined(separator: " and ")).\n\nIf it's already on, remove it with – and add it again. Then quit YKShot from the menu bar and reopen it."
        alert.addButton(withTitle: "Open Settings"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(first.pane)")!)
        }
        return false
    }

    // Drag = region, Space = window, Esc = cancel (all handled by macOS's own screencapture UI).
    @objc func capture() {
        guard permitted(accessibility: false) else { return }
        if running?.isRunning == true || pageBusy { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture.png")
        try? FileManager.default.removeItem(at: url)
        let wasVisible = window.isVisible
        window.orderOut(nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-i", url.path]
        p.terminationHandler = { _ in
            DispatchQueue.main.async { self.show(NSImage(contentsOf: url), reopen: wasVisible) }
        }
        try? p.run()
        running = p
    }

    private func show(_ img: NSImage?, reopen: Bool) {
        if let img {
            canvas.image = img
            stage.fit()
            let doc = stage.frame.size, screen = NSScreen.main?.visibleFrame.size ?? doc
            window.setContentSize(NSSize(width: max(760, min(doc.width, screen.width * 0.85)),
                                         height: max(300, min(doc.height, screen.height * 0.85))))
            window.center()
            // Fit the shot in the window (tall full pages: fit the width), never enlarge it.
            let view = scroll.contentSize
            let fit = doc.height > doc.width * 2 ? view.width / doc.width : min(view.width / doc.width, view.height / doc.height)
            scroll.magnification = min(1, fit)
            stage.scroll(.zero)   // start at the top
            let px = img.representations.first
            window.subtitle = "\(px?.pixelsWide ?? 0) × \(px?.pixelsHigh ?? 0)"
        } else if !reopen {
            return   // cancelled with Esc and nothing was open: stay in the tray
        }
        // A menu-bar app isn't always allowed to come forward by itself (macOS 14+): force the window on top, then take focus.
        window.orderFrontRegardless()
        window.makeKey()
        NSApp.activate()
    }

    @objc func pickTool(_ s: NSSegmentedControl) { canvas.tool = Tool(rawValue: s.selectedSegment) ?? .pen }
    @objc func pickColor(_ m: NSMenuItem) {
        guard let c = m.representedObject as? NSColor else { return }
        canvas.color = c
        colorPicker.item(at: 0)?.image = swatch(c)
    }
    @objc func undoMark() { _ = canvas.marks.popLast() }

    private var fileName: String {
        "Screenshot \(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: ".")).png"
    }

    @objc func copyImage() {
        guard let data = canvas.png() else { return }
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        // Chat/doc apps shrink big pasted images (a full page becomes unreadable). With the PNG file on the
        // clipboard too, most attach the original file instead. ponytail: 2000pt cutoff is a guess, tune if needed.
        if canvas.bounds.height > 2000 {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            if (try? data.write(to: url)) != nil { item.setString(url.absoluteString, forType: .fileURL) }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
        window.close()   // copied: done with this shot, get out of the way (app stays in the menu bar)
    }

    @objc func saveImage() {
        guard let data = canvas.png() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = fileName
        panel.beginSheetModal(for: window) { r in
            if r == .OK, let url = panel.url {
                do { try data.write(to: url) } catch { NSAlert(error: error).runModal() }
            }
        }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // tray only, no Dock icon
app.run()
