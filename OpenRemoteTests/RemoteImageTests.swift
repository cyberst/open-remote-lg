import XCTest
import ImageIO
import CryptoKit
@testable import OpenRemote

@MainActor
final class RemoteImageTests: XCTestCase {
    // SHA-256 of straight RGBA8 decoded from the approved prepared artwork.
    // MR19 was refreshed on 2026-11-11; the other baselines predate lossless optimization.
    private let approvedRGBA: [String: String] = [
        "magic-mr19": "613d633ec53944b1f7d96d7b6e856d2194e823361be50bec56ec01a1545a5dcd",
        "magic-mr21": "952cf74849538e6dc275b8fee14e9bf81dd63d7fe6ea685a7911df1da5675c9b",
        "magic-mr23": "bcb2afed8ce43939941a18240233cb97fcac32644dfb3759d5200bb167a97477",
        "magic-mr400": "723d81e18a31b49ce47322dbb2bfebbe71843f58f4c4a51c1128276b323e83bd",
        "standard-6710t00017v": "7f8d54bff63e036ece6047a988eb0ad45f76050bb9106221f9dff0a8a6ba6a53",
        "standard-akb69680403": "079d0ac4e84a2b4dc5ca07477c7872373ee67d4a5a01854da74d62d3ecd79eff",
        "standard-akb72914043": "910e66c05e80cd942d6b944f5e5ab5151074e776fc9f8f56a80a4ccc08430395",
        "standard-akb72915207": "75f4f4906e4683b174655d9971da3483d8ab63c81985dcddbc6ac9d195fa8b64",
        "standard-akb73655802": "0354c7270fb1c106e32f3f912b23d027739f0c094b9c6b98c586b57fc0aa1001",
        "standard-akb73715603": "90d1ad64d974ca98a900c6d5651146135ef9a29b227f2975b6ca33a23829b9fb",
        "standard-akb74475404": "5110601e499179c352f6f2d2668dd9111e75d02d35c9894699a530e2627d151b",
        "standard-akb74915324": "0e1680f23a53bb6f053c58f1f4998a5e0586d594478e8e331fa3451f7b474b2d",
        "standard-akb75095308": "694c282d511ad5a7bcd6d9cec0b25669f65cf5abb525a7209eaeec4b83cb3c5d",
        "standard-mkj40653802": "885bf875b35331b43eadd0b11403b394e9de49cb977f8c3c449ecc77c433918d",
    ]

    private func decode(_ url: URL, requireStraight: Bool = true) throws -> (CGImage, Data) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0,
            [kCGImageSourceShouldCache: false] as CFDictionary))
        XCTAssertEqual(image.bitsPerComponent, 8)
        XCTAssertEqual(image.bitsPerPixel, 32)
        if requireStraight { XCTAssertEqual(image.alphaInfo, .last) }
        XCTAssertEqual(image.bitmapInfo.intersection(.byteOrderMask).rawValue, 0)
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)
        let data = try XCTUnwrap(image.dataProvider?.data)
        let bytes = CFDataGetBytePtr(data)!
        var rgba = Data()
        for y in 0..<image.height {
            rgba.append(bytes.advanced(by: y * image.bytesPerRow), count: image.width * 4)
        }
        return (image, rgba)
    }

    private func render(_ image: CGImage) throws -> Data {
        var bytes = Data(count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { out in
            let context = try XCTUnwrap(CGContext(data: out.baseAddress,
                width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    func testEveryBundledRemoteIsPixelExactAndLoads() throws {
        let catalog = RemoteCatalog.shared
        XCTAssertFalse(catalog.isPlaceholder)
        XCTAssertEqual(Set(catalog.remotes.map(\.id)), Set(approvedRGBA.keys))
        for spec in catalog.remotes {
            let url = try XCTUnwrap(RemoteCatalog.resourceURL(spec.image, bundle: .main))
            let (image, rgba) = try decode(url)
            XCTAssertEqual(image.width, Int(spec.imageSize[0]), spec.id)
            XCTAssertEqual(image.height, 2400, spec.id)
            let hash = SHA256.hash(data: rgba).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hash, approvedRGBA[spec.id], spec.id)
            // Exercise both production loading paths, including the thumbnail used by RemoteCanvas.
            XCTAssertNotNil(RemoteImageStore.image(for: spec), spec.id)
            let thumbnail = try XCTUnwrap(RemoteImageStore.image(for: spec, maxPixelHeight: 1200))
            XCTAssertEqual(thumbnail.cgImage?.height, 1200, spec.id)

            // Optional pre-optimization fixtures enable a direct byte-for-byte iOS
            // comparison when evaluating a new codec; never include them in the app.
            let fixtures = Bundle(for: Self.self)
            // .baseline contains PNG bytes, copied verbatim instead of Xcode's CgBI conversion.
            if let original = fixtures.url(forResource: "original-" + spec.id, withExtension: "baseline") {
                // iOS ImageIO exposes PNG as premultiplied RGBA but WebP as straight
                // RGBA. Compare both rendered into the same RGBA8 representation.
                // The original straight hash above separately proves hidden RGB.
                let (before, _) = try decode(original, requireStraight: false)
                XCTAssertEqual(try render(image), try render(before), spec.id)
                XCTAssertEqual(image.colorSpace?.copyICCData(), before.colorSpace?.copyICCData(), spec.id)
            }
        }
    }
}
