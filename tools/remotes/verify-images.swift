#!/usr/bin/env swift
import Foundation
import ImageIO
import CryptoKit

// Compare straight RGBA, including RGB hidden behind zero alpha. Drawing into a
// CGContext alone would premultiply alpha and could conceal changes to those bytes.
// Also compare a colour-managed sRGB rendering and the source colour profile.
struct Pixels {
    let width: Int
    let height: Int
    let rgba: Data
    let rendered: Data
    let profile: Data
    let orientation: Int

    init(_ path: String) throws {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              image.bitsPerComponent == 8, image.bitsPerPixel == 32,
              image.bitmapInfo.intersection(.byteOrderMask).isEmpty,
              image.alphaInfo == .last || image.alphaInfo == .noneSkipLast,
              let provider = image.dataProvider?.data,
              let space = image.colorSpace,
              let icc = space.copyICCData() else {
            throw Failure("Unsupported straight RGBA8 decode: \(path) (refusing a potentially lossy conversion)")
        }
        let width = image.width, height = image.height
        self.width = width
        self.height = height
        profile = icc as Data
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let input = CFDataGetBytePtr(provider)!
        var straight = Data(count: width * height * 4)
        straight.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            for y in 0..<height {
                out.baseAddress!.advanced(by: y * width * 4)
                    .copyMemory(from: input.advanced(by: y * image.bytesPerRow), byteCount: width * 4)
            }
            if image.alphaInfo == .noneSkipLast {
                for i in stride(from: 3, to: out.count, by: 4) { out[i] = 255 }
            }
        }
        rgba = straight
        var display = Data(count: width * height * 4)
        let drawn = display.withUnsafeMutableBytes { out -> Bool in
            guard let context = CGContext(data: out.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw Failure("Cannot render \(path)") }
        rendered = display
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func compare(_ old: String, _ new: String) throws {
    let a = try Pixels(old), b = try Pixels(new)
    guard a.width == b.width, a.height == b.height else { throw Failure("Dimensions changed: \(new)") }
    guard a.orientation == b.orientation else { throw Failure("Orientation changed: \(new)") }
    guard a.rgba == b.rgba else {
        let offset = zip(a.rgba, b.rgba).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? -1
        throw Failure("Straight RGBA differs at byte \(offset): \(new)")
    }
    guard a.profile == b.profile else { throw Failure("Colour profile changed: \(new)") }
    guard a.rendered == b.rendered else { throw Failure("sRGB rendering changed: \(new)") }
    print("IDENTICAL \(new) \(a.width)x\(a.height) RGBA8 sha256=\(SHA256.hash(data: a.rgba))")
}

// Pair mode also supports comparing PNG against a candidate WebP.
// Tree mode compares every PNG/JPEG in the old tree with the same relative path
// in the new tree, or a .webp replacement if the original path no longer exists.
do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count == 3, args[0] == "--pair" || args[0] == "--tree" else {
        throw Failure("Usage: swift tools/remotes/verify-images.swift --pair OLD NEW | --tree OLD_ROOT NEW_ROOT")
    }
    if args[0] == "--pair" {
        try compare(args[1], args[2])
        print("PASS: 1 image; every RGBA8 byte, dimensions, profile and sRGB rendering identical")
    } else {
        let oldRoot = URL(fileURLWithPath: args[1], isDirectory: true).standardizedFileURL
        let newRoot = URL(fileURLWithPath: args[2], isDirectory: true).standardizedFileURL
        let files = FileManager.default.enumerator(at: oldRoot, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.path < $1.path }
        guard !files.isEmpty else { throw Failure("No images in old tree") }
        for old in files {
            let relative = String(old.path.dropFirst(oldRoot.path.count + 1))
            var new = newRoot.appendingPathComponent(relative)
            if !FileManager.default.fileExists(atPath: new.path) {
                new = new.deletingPathExtension().appendingPathExtension("webp")
            }
            try autoreleasepool { try compare(old.path, new.path) }
        }
        print("PASS: \(files.count) images; every RGBA8 byte, dimensions, profile and sRGB rendering identical")
    }
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
