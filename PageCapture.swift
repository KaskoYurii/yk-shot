import AppKit

/// Full-page capture: scrolls the real topmost window and stitches the frames,
/// so it works in any browser and keeps your logged-in session. Captures only the page, not the browser UI.
enum PageCapture {
    // ponytail: hard cap on frames, raise if very long pages get cut off (memory grows ~20 MB per frame).
    static let maxFrames = 60
    static let minScore = 0.6
    static let cols = 32        // each row is compared as 32 blocks, so a hover/animation only spoils its own blocks
    static let scrollbar = 16.0 // pt trimmed from the right: scrollbar + where the cursor is parked

    struct Frame { let bytes: [UInt8]; let sig: [UInt8] }   // sig: rows × cols average brightness

    static var point = CGPoint.zero   // where scroll events are aimed

    /// Runs on a background thread. Returns nil if there's no window to capture.
    static func run() -> NSImage? {
        usleep(250_000)   // let our own editor window disappear first
        guard let (pid, window) = topWindow() else { return nil }
        let page = webArea(pid: pid, in: window).map { $0.intersection(window) }
        let area = page ?? window
        let shot = CGRect(x: area.minX, y: area.minY, width: area.width - scrollbar, height: area.height).integral

        // Scroll events go to what's under the cursor: park it on the scrollbar strip (trimmed from the shot),
        // so the page never sees a hover. Restore it afterwards.
        let oldCursor = CGEvent(source: nil)?.location
        point = CGPoint(x: area.maxX - 6, y: area.midY)
        CGWarpMouseCursorPosition(point)
        defer { if let oldCursor { CGWarpMouseCursorPosition(oldCursor) } }

        for _ in 0..<5 { scroll(by: 100_000) }   // jump to the top of the page
        usleep(500_000)

        guard let first = grab(shot) else { return nil }
        let (w, h, space) = (first.width, first.height, first.colorSpace)
        let scale = Double(w) / shot.width
        let rowBytes = w * 4
        let step = Int32(shot.height * 0.5)      // scroll half a page: plenty of overlap to match on
        let expected = Int(Double(step) * scale)

        var prev = frame(first)
        var out: [UInt8] = []
        var end = 0   // rows of `prev` already in `out` (exclusive end)
        func append(_ f: Frame, _ rows: Range<Int>) { out += f.bytes[rows.lowerBound * rowBytes ..< rows.upperBound * rowBytes] }

        for _ in 1..<maxFrames {
            scroll(by: -step)
            usleep(400_000)   // smooth scrolling + lazy-loaded content
            guard let img = grab(shot), img.width == w, img.height == h else { break }
            let cur = frame(img)
            guard let a = align(prev: prev.sig, cur: cur.sig, expected: expected) else { break }
            if out.isEmpty { append(prev, 0 ..< h - a.bottom); end = h - a.bottom }
            // Near the end the page may move only a few px while the footer grows: nothing new to add then.
            let new = max(end - a.shift, a.top) ..< max(end - a.shift, a.top, h - a.bottom)
            append(cur, new)
            end = new.upperBound
            prev = cur
        }
        append(prev, (out.isEmpty ? 0 : end) ..< h)   // fixed footer of the last frame (or the single frame)

        let rows = out.count / rowBytes
        guard let provider = CGDataProvider(data: Data(out) as CFData),
              let cg = CGImage(width: w, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                               space: space ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: Double(w) / scale, height: Double(rows) / scale))
    }

    /// Compares two consecutive frames (row × block brightness, ±2 tolerance for re-rendering noise).
    /// top/bottom = rows that stayed put (sticky header/footer), shift = how far the content between them moved.
    /// nil = didn't move (end of page) or no reliable match.
    static func align(prev: [UInt8], cur: [UInt8], expected: Int) -> (top: Int, bottom: Int, shift: Int)? {
        let h = prev.count / cols
        func sameRow(_ r: Int) -> Bool { (0..<cols).allSatisfy { abs(Int(prev[r * cols + $0]) - Int(cur[r * cols + $0])) <= 2 } }
        guard let top = (0..<h).first(where: { !sameRow($0) }) else { return nil }   // unchanged: end of page
        let bottom = (0..<h).first(where: { !sameRow(h - 1 - $0) })!
        let n = h - bottom - top
        var best = (score: 0.0, shift: 0)
        prev.withUnsafeBufferPointer { p in cur.withUnsafeBufferPointer { c in
            for s in stride(from: 1, through: n - max(n / 10, 1), by: 1) {
                let overlap = n - s, base = top * cols, off = s * cols
                var matches = 0
                for i in base ..< base + overlap * cols where abs(Int(c[i]) - Int(p[i + off])) <= 2 { matches += 1 }
                let score = Double(matches) / Double(overlap * cols)
                // Blank areas match at many shifts: on a tie, prefer the shift closest to how far we scrolled.
                if score > best.score + 1e-9 || (abs(score - best.score) < 1e-9 && abs(s - expected) < abs(best.shift - expected)) {
                    best = (score, s)
                }
            }
        }}
        // Not 1.0: see-through sticky headers and lazy images change part of the overlap, and those rows
        // are never copied (only rows below the overlap are). Scroll-triggered animations (marquees, fade-ins)
        // can drag a correct match lower, so a weaker score is trusted when the shift ≈ the scroll we asked for.
        let plausible = abs(best.shift - expected) <= expected * 15 / 100 && best.score >= 0.3
        return best.score >= minScore || plausible ? (top, bottom, best.shift) : nil
    }

    static func frame(_ img: CGImage) -> Frame {
        let w = img.width, h = img.height, rowBytes = w * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * h)
        bytes.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: rowBytes,
                                space: img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let bw = max(w / cols, 1)
        var sig = [UInt8](repeating: 0, count: h * cols)
        bytes.withUnsafeBufferPointer { b in
            for r in 0..<h { for c in 0..<cols {
                var sum = 0
                for x in c * bw ..< min((c + 1) * bw, w) { let i = r * rowBytes + x * 4; sum += Int(b[i]) + Int(b[i + 1]) + Int(b[i + 2]) }
                sig[r * cols + c] = UInt8(sum / (3 * bw))
            }}
        }
        return Frame(bytes: bytes, sig: sig)
    }

    /// Owner pid and bounds of the topmost normal window that isn't ours.
    static func topWindow() -> (pid_t, CGRect)? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list {
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int, pid != Int(getpid()),
                  let b = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: b as CFDictionary), rect.height > 200
            else { continue }
            return (pid_t(pid), rect)
        }
        return nil
    }

    /// Screen rect of the web page inside the browser window (its outermost "AXWebArea"), via Accessibility.
    private static func webArea(pid: pid_t, in window: CGRect) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
            var v: AnyObject?
            return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
        }
        // Chrome/Electron only expose the page to Accessibility once a screen reader seems to be asking.
        let enhanced = "AXEnhancedUserInterface"
        let wasEnhanced = attr(app, enhanced) as? Bool ?? false
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, enhanced as CFString, kCFBooleanTrue)
        defer { if !wasEnhanced { AXUIElementSetAttributeValue(app, enhanced as CFString, kCFBooleanFalse) } }

        for _ in 1...8 {   // the tree can take a moment to appear the first time
            // Hit-test the middle of the window, then walk up; keep the outermost web area (not an iframe).
            var hit: AXUIElement?, found: CGRect?
            if AXUIElementCopyElementAtPosition(app, Float(window.midX), Float(window.midY), &hit) == .success, var el = hit {
                for _ in 0..<80 {
                    if attr(el, kAXRoleAttribute) as? String == "AXWebArea", let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute) {
                        var origin = CGPoint.zero, size = CGSize.zero
                        AXValueGetValue(p as! AXValue, .cgPoint, &origin)
                        AXValueGetValue(s as! AXValue, .cgSize, &size)
                        if size.height > 100 { found = CGRect(origin: origin, size: size) }
                    }
                    guard let parent = attr(el, kAXParentAttribute) else { break }
                    el = parent as! AXUIElement
                }
            }
            if let found { return found }
            usleep(250_000)
        }
        return nil
    }

    /// Screenshot of a screen rect (points, top-left origin). No cursor, no sound.
    static func grab(_ r: CGRect) -> CGImage? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("page-frame.png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-R", "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))", url.path]
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Positive = up. Continuous (trackpad-style) pixel scroll, so browsers apply it immediately.
    private static func scroll(by dy: Int32) {
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)
        e?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e?.location = point
        e?.post(tap: .cghidEventTap)
    }
}
