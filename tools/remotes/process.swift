#!/usr/bin/env swift
// macOS 14+, Apple frameworks only. Run from the project directory:
// swift tools/remotes/process.swift "/path/to/remote-inbox/" "OpenRemote/Resources/Remotes"
// Optional third argument: --mask=flood (deterministic fallback), --mask=vision (require Vision).
// Inbox is read-only. Matching output PNGs and contact-sheet.jpg are replaced.

import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

struct ProcessingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
func fail(_ message: String) -> ProcessingError { ProcessingError(message: message) }
func logError(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

struct Raster {
    let width: Int
    let height: Int
    var pixels: [UInt8] // premultiplied RGBA, image scanline order

    init(_ image: CGImage) throws {
        width = image.width
        height = image.height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        let w = width, h = height
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let ctx = CGContext(data: bytes.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: rgb, bitmapInfo: bitmapInfo) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw fail("Cannot allocate RGBA raster.") }
    }

    func image() throws -> CGImage {
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data),
              let result = CGImage(width: width, height: height, bitsPerComponent: 8,
                                   bitsPerPixel: 32, bytesPerRow: width * 4, space: rgb,
                                   bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                                   provider: provider, decode: nil, shouldInterpolate: true,
                                   intent: .defaultIntent) else { throw fail("Cannot create RGBA image.") }
        return result
    }
}

func load(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // JPEG EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: 4096,
            kCGImageSourceShouldCacheImmediately: true
          ] as CFDictionary) else {
        throw fail("Cannot decode \(url.lastPathComponent). Use a genuine PNG/JPEG/WebP supported by ImageIO; renaming a different format is insufficient.")
    }
    return image
}

func save(_ image: CGImage, to url: URL, jpeg: Bool = false) throws {
    let data = NSMutableData()
    let type = jpeg ? UTType.jpeg.identifier : UTType.png.identifier
    guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else {
        throw fail("Cannot create image encoder for \(url.lastPathComponent).")
    }
    let options: [CFString: Any] = jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.9] : [:]
    CGImageDestinationAddImage(destination, image, options as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw fail("Image encoding failed.") }
    try (data as Data).write(to: url, options: .atomic)
}

// Visit a four-connected region without recursion (large pure-white backgrounds are common).
func flood(width: Int, height: Int, seeds: [Int], eligible: (Int) -> Bool) -> [Bool] {
    var visited = [Bool](repeating: false, count: width * height)
    var queue = [Int]()
    for seed in seeds where !visited[seed] && eligible(seed) {
        visited[seed] = true
        queue.append(seed)
    }
    var head = 0
    while head < queue.count {
        let p = queue[head]; head += 1
        let x = p % width, y = p / width
        func enqueue(_ n: Int) {
            if !visited[n] && eligible(n) { visited[n] = true; queue.append(n) }
        }
        if x > 0 { enqueue(p - 1) }
        if x + 1 < width { enqueue(p + 1) }
        if y > 0 { enqueue(p - width) }
        if y + 1 < height { enqueue(p + width) }
    }
    return visited
}

func edgePixels(width: Int, height: Int) -> [Int] {
    var result = Array(0..<width) + Array(((height - 1) * width)..<(height * width))
    if height > 2 {
        for y in 1..<(height - 1) { result.append(y * width); result.append(y * width + width - 1) }
    }
    return result
}

// Only erase near-white pixels reachable from an edge. Enclosed white keycaps and
// white print remain opaque. Shadows darker than the threshold cannot be inferred away.
func whiteMask(_ source: Raster) -> [UInt8] {
    let w = source.width, h = source.height, p = source.pixels
    let outside = flood(width: w, height: h, seeds: edgePixels(width: w, height: h)) { i in
        let j = i * 4
        if p[j + 3] < 16 { return true }
        let low = min(p[j], p[j + 1], p[j + 2]), high = max(p[j], p[j + 1], p[j + 2])
        return low >= 238 && Int(high) - Int(low) <= 20
    }
    return outside.map { $0 ? 0 : 255 }
}

@available(macOS 14.0, *)
func visionMask(_ image: CGImage) throws -> [UInt8] {
    let request = VNGenerateForegroundInstanceMaskRequest()
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    try handler.perform([request])
    guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
        throw fail("Vision found no foreground instance.")
    }
    let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
    let mask = CIImage(cvPixelBuffer: buffer)
    let context = CIContext(options: [.cacheIntermediates: false])
    guard let cgMask = context.createCGImage(mask, from: mask.extent, format: .RGBA8, colorSpace: rgb) else {
        throw fail("Vision mask conversion failed.")
    }
    let raster = try Raster(cgMask)
    guard raster.width == image.width, raster.height == image.height else { throw fail("Vision mask size mismatch.") }
    return stride(from: 0, to: raster.pixels.count, by: 4).map { raster.pixels[$0] }
}

// Keep the single largest connected silhouette, removing isolated segmentation specks.
// Fill its interior holes: these solid remotes have no through-holes, but do have white keys.
func solidSilhouette(_ mask: [UInt8], width w: Int, height h: Int) throws -> [UInt8] {
    var seen = [Bool](repeating: false, count: mask.count)
    var largest = [Int]()
    for start in mask.indices where !seen[start] && mask[start] >= 128 {
        var queue = [start], head = 0
        seen[start] = true
        while head < queue.count {
            let p = queue[head]; head += 1
            let x = p % w, y = p / w
            func add(_ n: Int) {
                if !seen[n] && mask[n] >= 128 { seen[n] = true; queue.append(n) }
            }
            if x > 0 { add(p - 1) }; if x + 1 < w { add(p + 1) }
            if y > 0 { add(p - w) }; if y + 1 < h { add(p + w) }
        }
        if queue.count > largest.count { largest = queue }
    }
    guard largest.count > 64, largest.count < Int(Double(w * h) * 0.95) else {
        throw fail("No useful isolated remote silhouette; check that the source has white margin on every edge.")
    }
    var core = [Bool](repeating: false, count: mask.count)
    for i in largest { core[i] = true }
    let exterior = flood(width: w, height: h, seeds: edgePixels(width: w, height: h)) { !core[$0] }
    var result = [UInt8](repeating: 0, count: mask.count)
    for i in result.indices {
        if !exterior[i] { result[i] = 255 }
        else if mask[i] > 0 && mask[i] < 128 {
            // Keep only soft edge pixels adjacent to this silhouette.
            let x = i % w, y = i / w
            if (x > 0 && core[i - 1]) || (x + 1 < w && core[i + 1]) ||
               (y > 0 && core[i - w]) || (y + 1 < h && core[i + w]) { result[i] = mask[i] }
        }
    }
    return result
}

func cutout(_ image: CGImage, mode: String) throws -> (CGImage, String) {
    var raster = try Raster(image)
    let edges = edgePixels(width: raster.width, height: raster.height)
    let transparentEdges = edges.filter { raster.pixels[$0 * 4 + 3] < 16 }.count
    var mask: [UInt8], method: String
    // Preserve a genuinely transparent input rather than trying to segment it again.
    if transparentEdges > edges.count / 2 {
        mask = stride(from: 3, to: raster.pixels.count, by: 4).map { raster.pixels[$0] }
        method = "existing alpha"
    } else if mode != "flood" {
        do {
            if #available(macOS 14.0, *) {
                let candidate = try visionMask(image)
                mask = try solidSilhouette(candidate, width: raster.width, height: raster.height)
                method = "Vision"
            } else { throw fail("Vision instance masks need macOS 14 or newer.") }
        } catch {
            if mode == "vision" { throw error }
            logError("  Vision unavailable/unsuitable (\(error.localizedDescription)); using edge-connected white flood fill.")
            mask = whiteMask(raster)
            method = "white flood fill"
        }
    } else {
        mask = whiteMask(raster)
        method = "white flood fill"
    }
    if method != "Vision" && method != "existing alpha" {
        mask = try solidSilhouette(mask, width: raster.width, height: raster.height)
    }
    for i in mask.indices {
        let j = i * 4
        // RGB is already premultiplied by source alpha. Multiplying all four
        // channels preserves correct premultiplication for resampling/export.
        if method != "existing alpha" {
            for c in 0..<4 { raster.pixels[j + c] = UInt8((Int(raster.pixels[j + c]) * Int(mask[i]) + 127) / 255) }
        }
    }
    var minX = raster.width, minY = raster.height, maxX = -1, maxY = -1
    for y in 0..<raster.height {
        for x in 0..<raster.width where raster.pixels[(y * raster.width + x) * 4 + 3] > 8 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX > minX, maxY > minY else { throw fail("Empty or degenerate foreground.") }
    let contentWidth = maxX - minX + 1, contentHeight = maxY - minY + 1
    // Crop just the content, then add transparent margin even if input touched an edge.
    guard let crop = try raster.image().cropping(to: CGRect(x: minX, y: minY, width: contentWidth, height: contentHeight)) else {
        throw fail("Cannot crop foreground.")
    }
    let margin = max(2, Int((Double(contentHeight) * 0.005).rounded()))
    let scale = 2400.0 / Double(contentHeight + margin * 2)
    let outputWidth = max(1, Int((Double(contentWidth + margin * 2) * scale).rounded()))
    guard let context = CGContext(data: nil, width: outputWidth, height: 2400,
                                  bitsPerComponent: 8, bytesPerRow: outputWidth * 4,
                                  space: rgb, bitmapInfo: bitmapInfo) else { throw fail("Cannot allocate output.") }
    context.interpolationQuality = .high
    // Use the same scale on both axes; extra width from integer rounding stays transparent.
    let drawWidth = Double(contentWidth) * scale
    context.draw(crop, in: CGRect(x: (Double(outputWidth) - drawWidth) / 2,
                                  y: Double(margin) * scale,
                                  width: drawWidth, height: Double(contentHeight) * scale))
    guard let output = context.makeImage() else { throw fail("Cannot create output.") }
    return (output, method)
}

func contactSheet(_ urls: [URL], to destination: URL) throws {
    let columns = min(4, urls.count), rows = (urls.count + columns - 1) / columns
    let cellWidth = 280, cellHeight = 680, w = columns * cellWidth, h = rows * cellHeight
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: rgb, bitmapInfo: bitmapInfo) else { throw fail("Cannot allocate contact sheet.") }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.interpolationQuality = .high
    for (index, url) in urls.enumerated() {
        let image = try load(url)
        let x = (index % columns) * cellWidth, y = h - ((index / columns) + 1) * cellHeight
        // Checkerboard exposes transparent borders and white keycaps in the JPEG preview.
        for ty in stride(from: y + 65, to: y + cellHeight - 12, by: 16) {
            for tx in stride(from: x + 8, to: x + cellWidth - 8, by: 16) {
                ctx.setFillColor(CGColor(gray: ((tx / 16 + ty / 16) % 2 == 0) ? 0.94 : 0.87, alpha: 1))
                ctx.fill(CGRect(x: tx, y: ty, width: min(16, x + cellWidth - 8 - tx), height: min(16, y + cellHeight - 12 - ty)))
            }
        }
        let scale = min(Double(cellWidth - 40) / Double(image.width), Double(cellHeight - 95) / Double(image.height))
        let iw = Double(image.width) * scale, ih = Double(image.height) * scale
        ctx.draw(image, in: CGRect(x: Double(x) + (Double(cellWidth) - iw) / 2, y: Double(y + 75), width: iw, height: ih))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
                                                   .foregroundColor: NSColor.black, .paragraphStyle: paragraph]
        let label = url.deletingPathExtension().lastPathComponent + "\n\(image.width) × \(image.height)"
        (label as NSString).draw(in: CGRect(x: x + 6, y: y + 8, width: cellWidth - 12, height: 48), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }
    guard let sheet = ctx.makeImage() else { throw fail("Cannot create contact sheet.") }
    try save(sheet, to: destination, jpeg: true)
}

func main() throws {
    guard #available(macOS 14.0, *) else { throw fail("Requires macOS 14 or newer.") }
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count == 2 || args.count == 3 else {
        throw fail("Usage: swift tools/remotes/process.swift <inbox> <outdir> [--mask=flood|--mask=vision]")
    }
    let mode = args.count == 3 ? args[2] : "auto"
    guard ["auto", "--mask=flood", "--mask=vision"].contains(mode) else { throw fail("Unknown mask option: \(mode)") }
    let fm = FileManager.default
    let inbox = URL(fileURLWithPath: args[0], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    let outdir = URL(fileURLWithPath: args[1], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    guard outdir.path != inbox.path, !outdir.path.hasPrefix(inbox.path + "/") else {
        throw fail("Output directory must be outside the inbox; source files are read-only.")
    }
    let files = try fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        .filter { ["png", "jpg", "jpeg", "webp"].contains($0.pathExtension.lowercased()) && ((try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !files.isEmpty else { throw fail("No PNG/JPEG/WebP files in \(inbox.path).") }
    var ids = Set<String>()
    for file in files {
        let id = file.deletingPathExtension().lastPathComponent
        guard id.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil else { throw fail("Invalid id: \(id). Use the remote id (lowercase, hyphen-separated) as the base filename.") }
        guard ids.insert(id.lowercased()).inserted else { throw fail("Duplicate input id \(id); keep only one extension per remote.") }
        // A symlink in an existing output directory must not lead a write into the inbox.
        let target = outdir.appendingPathComponent(id + ".png").resolvingSymlinksInPath()
        guard !target.path.hasPrefix(inbox.path + "/") else { throw fail("Output symlink points into the inbox.") }
    }
    try fm.createDirectory(at: outdir, withIntermediateDirectories: true)
    var failures = 0
    for file in files {
        do {
            try autoreleasepool {
                let image = try load(file)
                let (output, method) = try cutout(image, mode: mode.replacingOccurrences(of: "--mask=", with: ""))
                let target = outdir.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".png")
                try save(output, to: target)
                print("\(target.lastPathComponent): \(output.width) × \(output.height), \(method)")
            }
        } catch { failures += 1; logError("ERROR \(file.lastPathComponent): \(error.localizedDescription)") }
    }
    let outputs = try fm.contentsOfDirectory(at: outdir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        .filter { $0.pathExtension.lowercased() == "png" && ((try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    if !outputs.isEmpty {
        let sheet = outdir.appendingPathComponent("contact-sheet.jpg")
        guard !sheet.resolvingSymlinksInPath().path.hasPrefix(inbox.path + "/") else { throw fail("Contact sheet symlink points into inbox.") }
        try contactSheet(outputs, to: sheet)
        print("Contact sheet: \(sheet.path)")
    }
    if failures > 0 { throw fail("\(failures) input(s) failed. Successful outputs remain; fix the reported sources and rerun.") }
}

do { try main() } catch { logError(error.localizedDescription); exit(1) }
