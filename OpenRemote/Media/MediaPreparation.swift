import AVFoundation
import CoreTransferable
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Scratch space for media being cast. Everything lives under one temp folder that is wiped when casting ends.
enum CastStorage {
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("Cast", isDirectory: true)

    static func newFileURL(ext: String) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    /// Copies a file handed over by PhotosPicker (only valid inside the import closure) into our folder.
    static func copyIn(_ file: URL) throws -> URL {
        let ext = file.pathExtension.isEmpty ? "dat" : file.pathExtension.lowercased()
        let dest = try newFileURL(ext: ext)
        try FileManager.default.copyItem(at: file, to: dest)
        return dest
    }

    static func remove(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func removeAll() { try? FileManager.default.removeItem(at: root) }
}

/// A picked photo, as the original file (HEIC, JPEG, PNG, …).
struct PickedImageFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { PickedImageFile(url: try CastStorage.copyIn($0.file)) }
    }
}

/// A picked video, as the original file (usually .mov).
struct PickedMovieFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { PickedMovieFile(url: try CastStorage.copyIn($0.file)) }
    }
}

enum MediaPrepError: LocalizedError {
    case unreadableImage
    case unreadableVideo
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadableImage: String(localized: "This photo couldn't be read.")
        case .unreadableVideo: String(localized: "This video couldn't be read.")
        case .exportFailed(let m): String(localized: "This video couldn't be prepared for the TV. \(m)")
        }
    }
}

/// Photo conversion: any ImageIO-readable format → sRGB JPEG, long edge ≤ 3840 px, orientation applied,
/// and no metadata copied (so location and camera data never reach the TV).
enum PhotoConverter {
    static let tvMaxPixel = 3840

    static func makeJPEG(from source: URL, maxPixel: Int = tvMaxPixel, quality: Double = 0.88) throws -> URL {
        let image = try downsample(source, maxPixel: maxPixel)
        let dest = try CastStorage.newFileURL(ext: "jpg")
        guard let out = CGImageDestinationCreateWithURL(dest as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw MediaPrepError.unreadableImage
        }
        CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(out) else { throw MediaPrepError.unreadableImage }
        return dest
    }

    static func thumbnail(of source: URL, maxPixel: Int = 320) -> UIImage? {
        (try? downsample(source, maxPixel: maxPixel)).map { UIImage(cgImage: $0) }
    }

    static func downsample(_ source: URL, maxPixel: Int) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw MediaPrepError.unreadableImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // bake in EXIF orientation
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { throw MediaPrepError.unreadableImage }
        return toSRGB(image) ?? image
    }

    /// Wide-gamut / 16-bit images look washed out or fail on older TVs; flatten to 8-bit sRGB.
    private static func toSRGB(_ image: CGImage) -> CGImage? {
        if image.colorSpace?.name == CGColorSpace.sRGB, image.bitsPerComponent == 8 { return image }
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }
}

/// Video preparation: webOS plays H.264/HEVC + AAC in MP4. Compatible videos are remuxed to .mp4 without
/// re-encoding (fast, lossless); anything else is re-encoded to 1080p H.264.
enum VideoConverter {
    struct Prepared { var url: URL; var duration: TimeInterval; var reencoded: Bool }

    static let tvVideoCodecs: Set<FourCharCode> = [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC, fourCC("hev1")]
    static let tvAudioCodecs: Set<FourCharCode> = [kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatAC3, kAudioFormatEnhancedAC3]

    static func thumbnail(of url: URL, maxPixel: CGFloat = 320) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        guard let image = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image else { return nil }
        return UIImage(cgImage: image)
    }

    static func prepare(_ source: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Prepared {
        let asset = AVURLAsset(url: source)
        let duration: CMTime
        let videoTracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration)
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } catch { throw MediaPrepError.unreadableVideo }
        guard !videoTracks.isEmpty else { throw MediaPrepError.unreadableVideo }
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []

        var compatible = true
        for t in videoTracks where !(await codecs(of: t)).isSubset(of: tvVideoCodecs) { compatible = false }
        for t in audioTracks where !(await codecs(of: t)).isSubset(of: tvAudioCodecs) { compatible = false }
        var preset = AVAssetExportPresetPassthrough
        if compatible {
            compatible = await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: .mp4)
        }
        if !compatible { preset = AVAssetExportPreset1920x1080 }

        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw MediaPrepError.exportFailed("No export session.")
        }
        session.shouldOptimizeForNetworkUse = true // moov atom first, so the TV can start playing immediately
        let dest = try CastStorage.newFileURL(ext: "mp4")
        try await export(session, to: dest, progress: progress)
        return Prepared(url: dest, duration: duration.seconds.isFinite ? duration.seconds : 0, reencoded: !compatible)
    }

    private static func export(_ session: AVAssetExportSession, to dest: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        if #available(iOS 18, *) {
            let watcher = Task {
                for await state in session.states(updateInterval: 0.25) {
                    if case .exporting(let p) = state { progress(p.fractionCompleted) }
                }
            }
            defer { watcher.cancel() }
            do { try await session.export(to: dest, as: .mp4) } catch {
                CastStorage.remove(dest)
                throw error is CancellationError ? error : MediaPrepError.exportFailed(error.localizedDescription)
            }
        } else {
            session.outputURL = dest
            session.outputFileType = .mp4
            let watcher = Task {
                while !Task.isCancelled {
                    progress(Double(session.progress))
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { watcher.cancel() }
            await withTaskCancellationHandler { await session.export() } onCancel: { session.cancelExport() }
            guard session.status == .completed else {
                CastStorage.remove(dest)
                if Task.isCancelled { throw CancellationError() }
                throw MediaPrepError.exportFailed(session.error?.localizedDescription ?? "")
            }
        }
        progress(1)
    }

    private static func codecs(of track: AVAssetTrack) async -> Set<FourCharCode> {
        let descs = (try? await track.load(.formatDescriptions)) ?? []
        return Set(descs.map { CMFormatDescriptionGetMediaSubType($0) })
    }

    private static func fourCC(_ s: String) -> FourCharCode { s.utf8.reduce(0) { $0 << 8 | FourCharCode($1) } }
}
