#!/usr/bin/env swift
// Synthetic end-to-end checks; no references or owner's inbox are read.
// Run: swift tools/remotes/test-process.swift [--keep]
// Temporary fixtures are deleted unless --keep is supplied for visual inspection.
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "RemoteProcessorTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("remote-processor-test-" + UUID().uuidString)
let inbox = root.appendingPathComponent("inbox"), output = root.appendingPathComponent("output")
let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("process.swift")
let keep = CommandLine.arguments.contains("--keep")
defer { if !keep { try? fm.removeItem(at: root) } }

func fixture(_ name: String, type: UTType = .png, whiteOnly: Bool = false) throws {
    let ctx = CGContext(data: nil, width: 400, height: 800, bitsPerComponent: 8, bytesPerRow: 1600,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 800))
    if !whiteOnly {
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 130, y: 70, width: 140, height: 660), cornerWidth: 22, cornerHeight: 22, transform: nil)); ctx.fillPath()
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 165, y: 360, width: 70, height: 80))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 175, y: 150, width: 50, height: 50))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 175, y: 600, width: 50, height: 50))
    }
    let dest = CGImageDestinationCreateWithURL(inbox.appendingPathComponent(name) as CFURL, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.98] as CFDictionary)
    try require(CGImageDestinationFinalize(dest), "Could not encode fixture")
}
@discardableResult
func run(_ source: URL, _ target: URL, _ option: String? = nil, success: Bool = true) throws -> String {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    process.arguments = [script.path, source.path, target.path] + (option.map { [$0] } ?? [])
    process.standardOutput = pipe; process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    print(text, terminator: "")
    try require((process.terminationStatus == 0) == success, "Unexpected exit status: \(process.terminationStatus)")
    return text
}
func inspect(_ name: String, in directory: URL) throws {
    let url = directory.appendingPathComponent(name + ".png")
    let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
    try require(image.height == 2400, "Output height must be 2400")
    try require((520...550).contains(image.width), "Crop/proportion incorrect: \(image.width)")
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let w = image.width, h = image.height
    pixels.withUnsafeMutableBytes { bytes in
        let ctx = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    func sample(_ x: Double, _ y: Double) -> [UInt8] {
        let i = (Int(y * Double(h)) * w + Int(x * Double(w))) * 4
        return Array(pixels[i..<(i + 4)])
    }
    try require(sample(0, 0)[3] == 0 && sample(0.5, 0)[3] == 0, "Margin must be transparent")
    let white = sample(0.5, 0.5)
    try require(white[0] > 240 && white[1] > 240 && white[2] > 240 && white[3] == 255, "Enclosed white key was erased")
    // Core Graphics drew blue near the visual top and red near the visual bottom.
    let blue = sample(0.5, 0.16), red = sample(0.5, 0.84)
    try require(red[0] > 230 && red[2] < 25 && blue[2] > 230 && blue[0] < 25, "Image orientation/colour changed")
    try require(sample(0.5, 0.35)[3] == 255, "Body should stay opaque")
}

do {
    try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
    try fixture("synthetic.png")
    try fixture("synthetic-jpeg.jpg", type: .jpeg)
    let originalData = try Data(contentsOf: inbox.appendingPathComponent("synthetic.png"))
    try run(inbox, output, "--mask=flood")
    try inspect("synthetic", in: output); try inspect("synthetic-jpeg", in: output)
    let sheetURL = output.appendingPathComponent("contact-sheet.jpg")
    let sheet = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(sheetURL as CFURL, nil)!, 0, nil)!
    try require(sheet.width == 560 && sheet.height == 680, "Contact sheet has incorrect cell count")
    // Default path exercises Vision and, on unsupported hosts, its automatic fallback.
    let autoLog = try run(inbox, root.appendingPathComponent("auto"))
    try inspect("synthetic", in: root.appendingPathComponent("auto"))
    try require(autoLog.contains("Vision") || autoLog.contains("white flood fill"), "No extraction method reported")
    let unchangedData = try Data(contentsOf: inbox.appendingPathComponent("synthetic.png"))
    try require(unchangedData == originalData, "Inbox input changed")
    // Already-transparent output keeps its alpha and enclosed white keys when recropped.
    let alphaInbox = root.appendingPathComponent("alpha-inbox")
    try fm.createDirectory(at: alphaInbox, withIntermediateDirectories: true)
    try fm.copyItem(at: output.appendingPathComponent("synthetic.png"), to: alphaInbox.appendingPathComponent("synthetic.png"))
    try run(alphaInbox, root.appendingPathComponent("alpha"), "--mask=flood")
    try inspect("synthetic", in: root.appendingPathComponent("alpha"))
    try run(inbox, inbox.appendingPathComponent("nested-output"), success: false)
    try require(!fm.fileExists(atPath: inbox.appendingPathComponent("nested-output").path), "Nested inbox output was created")
    try fixture("synthetic.jpg", type: .jpeg)
    try run(inbox, root.appendingPathComponent("duplicate"), success: false)
    try require(!fm.fileExists(atPath: root.appendingPathComponent("duplicate").path), "Duplicate validation wrote output")
    try fm.removeItem(at: inbox.appendingPathComponent("synthetic.jpg"))
    try fixture("all-white.png", whiteOnly: true)
    try run(inbox, root.appendingPathComponent("white-check"), "--mask=flood", success: false)
    try require(!fm.fileExists(atPath: root.appendingPathComponent("white-check/all-white.png").path), "All-white source produced bogus artwork")
    print("PASS: PNG/JPEG extraction, white key preservation, alpha, orientation, tight crop, 2400px height, sheet, auto fallback, input preservation, duplicate/empty protection.")
    if keep { print("Synthetic QA files: \(root.path)") }
} catch {
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    if keep { print("Synthetic QA files: \(root.path)") }
    exit(1)
}
