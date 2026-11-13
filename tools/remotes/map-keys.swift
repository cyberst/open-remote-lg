// Converts a hand-measured key map (pixel centres/sizes on the ChatGPT source image) into normalised rects on the
// processed PNG, updates that remote's entry in remotes.json (keys + imageSize), and draws a debug overlay.
//
//   swift tools/remotes/map-keys.swift <keymap.json> <source image> <processed png> <remotes.json> <overlay.png>
//
// The source→processed transform is found from the silhouettes: the source remote's bounding box (opaque dark pixels)
// maps onto the processed PNG's opaque bounding box.
import AppKit
import Foundation

func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }

let a = CommandLine.arguments
guard a.count == 6 else { fail("usage: map-keys.swift <keymap.json> <source> <processed.png> <remotes.json> <overlay.png>") }

func bitmap(_ path: String) -> NSBitmapImageRep {
    guard let data = FileManager.default.contents(atPath: path), let rep = NSBitmapImageRep(data: data) else { fail("can't read \(path)") }
    // Normalise to RGBA8 so pixel reads are uniform.
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    rep.draw(in: NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
    NSGraphicsContext.restoreGraphicsState()
    return out
}

/// Bounding box (top-left origin, pixels) of pixels passing `test(r,g,b,a)`.
func bbox(_ rep: NSBitmapImageRep, _ test: (Int, Int, Int, Int) -> Bool) -> CGRect {
    let w = rep.pixelsWide, h = rep.pixelsHigh, p = rep.bitmapData!, bpr = rep.bytesPerRow
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h { for x in 0..<w {
        let o = y * bpr + x * 4
        if test(Int(p[o]), Int(p[o + 1]), Int(p[o + 2]), Int(p[o + 3])) {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    } }
    guard maxX >= 0 else { fail("empty silhouette") }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

struct KeyIn: Decodable { let id: String; let action: String; let shape: String; let c: [Double]; let s: [Double] }
struct MapIn: Decodable { let id: String; let keys: [KeyIn] }

let map = try! JSONDecoder().decode(MapIn.self, from: FileManager.default.contents(atPath: a[1])!)
let src = bitmap(a[2]), out = bitmap(a[3])
let sb = bbox(src) { r, g, b, al in al > 128 && min(r, g, b) < 200 } // white or transparent backdrop
let ob = bbox(out) { _, _, _, al in al > 128 }               // opaque remote on transparency
let sx = ob.width / sb.width, sy = ob.height / sb.height
let W = Double(out.pixelsWide), H = Double(out.pixelsHigh)
print(String(format: "source bbox %.0f,%.0f %.0fx%.0f → processed %.0f,%.0f %.0fx%.0f (scale %.4f / %.4f)",
             sb.minX, sb.minY, sb.width, sb.height, ob.minX, ob.minY, ob.width, ob.height, sx, sy))

var keys: [[String: Any]] = []
var rects: [(CGRect, String)] = []
for k in map.keys {
    let cx = ob.minX + (k.c[0] - sb.minX) * sx, cy = ob.minY + (k.c[1] - sb.minY) * sy
    let w = k.s[0] * sx, h = k.s[1] * sy
    let r = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    rects.append((r, k.id))
    func q(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
    keys.append(["id": k.id, "action": k.action, "shape": k.shape,
                 "rect": [q(r.minX / W), q(r.minY / H), q(r.width / W), q(r.height / H)]])
}

// Update remotes.json in place (keeps every other entry and field).
var root = try! JSONSerialization.jsonObject(with: FileManager.default.contents(atPath: a[4])!) as! [String: Any]
var remotes = root["remotes"] as! [[String: Any]]
guard let i = remotes.firstIndex(where: { ($0["id"] as? String) == map.id }) else { fail("no entry \(map.id) in remotes.json") }
remotes[i]["keys"] = keys
remotes[i]["imageSize"] = [out.pixelsWide, out.pixelsHigh]
root["remotes"] = remotes
let json = try! JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
try! json.write(to: URL(fileURLWithPath: a[4]))
print("\(map.id): \(keys.count) keys, imageSize \(out.pixelsWide)x\(out.pixelsHigh) → \(a[4])")

// Overlay: processed image on dark grey with every rect outlined and labelled.
let ctxRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: out.pixelsWide, pixelsHigh: out.pixelsHigh, bitsPerSample: 8,
                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let g = NSGraphicsContext(bitmapImageRep: ctxRep)!
NSGraphicsContext.current = g
NSColor(white: 0.25, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
out.draw(in: NSRect(x: 0, y: 0, width: W, height: H))
for (r, id) in rects {
    let flipped = NSRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height)
    NSColor.systemPink.withAlphaComponent(0.25).setFill(); flipped.fill()
    NSColor.systemPink.setStroke(); let p = NSBezierPath(rect: flipped); p.lineWidth = 3; p.stroke()
    (id as NSString).draw(at: NSPoint(x: flipped.minX + 3, y: flipped.minY + 2),
                          withAttributes: [.font: NSFont.boldSystemFont(ofSize: 22), .foregroundColor: NSColor.yellow])
}
NSGraphicsContext.restoreGraphicsState()
try! ctxRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])!.write(to: URL(fileURLWithPath: a[5]))
print("overlay → \(a[5])")
