// Self-check for the stitching math. Run: swiftc PageCapture.swift tests/main.swift -o /tmp/ykcheck && /tmp/ykcheck
// Signatures here use 32 identical blocks per row; values are "content ids" spaced > the ±2 tolerance.
let cols = PageCapture.cols
func sig(_ rows: [Int]) -> [UInt8] { rows.flatMap { v in Array(repeating: UInt8(v), count: cols) } }
let page = (0..<300).map { 20 + ($0 * 7) % 230 }          // distinct-ish rows
func shot(_ y: Int) -> [Int] { [0, 3] + Array(page[y..<y + 50]) + [255] }   // 2 sticky header rows, 1 footer

// Scrolled 20 rows: header (2) and footer (1) detected as fixed, shift 20.
let a = PageCapture.align(prev: sig(shot(0)), cur: sig(shot(20)), expected: 20)!
assert(a.top == 2 && a.bottom == 1 && a.shift == 20, "\(a)")

// See-through sticky header drawn over the first 10 content rows after scrolling: still aligns.
var overlaid = shot(20); for i in 2..<12 { overlaid[i] = 250 - i }
assert(PageCapture.align(prev: sig(shot(0)), cur: sig(overlaid), expected: 20)?.shift == 20)

// Hover effect redrawing the left half of most rows: block comparison still aligns.
var hovered = sig(shot(20)); for r in 2..<45 { for c in 0..<cols / 2 { hovered[r * cols + c] = 1 } }
assert(PageCapture.align(prev: sig(shot(0)), cur: hovered, expected: 20)?.shift == 20)

// Same picture = end of page.
assert(PageCapture.align(prev: sig(shot(30)), cur: sig(shot(30)), expected: 20) == nil)

// Unrelated frames (jumped too far) = no match.
assert(PageCapture.align(prev: sig(shot(0)), cur: sig(shot(200)), expected: 20) == nil)
print("ok")
