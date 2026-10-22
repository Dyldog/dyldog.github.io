import Foundation
import CoreGraphics
import ImageIO
import AVFoundation

struct ProcessingError: LocalizedError {
    var errorDescription: String?
}

enum ImageProcessing {
    /// Pixel size of the image as it should be displayed (EXIF orientation applied).
    static func uprightPixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation) ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// Decodes the image upright, optionally downsampled so its longest side is at most `maxPixelSize`.
    static func loadUpright(_ url: URL, maxPixelSize: Int? = nil) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let fullSize = uprightPixelSize(of: url).map { Int(max($0.width, $0.height)) } ?? 10_000
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixelSize ?? fullSize, fullSize),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func crop(_ image: CGImage, to normalized: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let rect = CGRect(
            x: normalized.minX * bounds.width,
            y: normalized.minY * bounds.height,
            width: normalized.width * bounds.width,
            height: normalized.height * bounds.height
        ).integral.intersection(bounds)
        return rect.isEmpty ? nil : image.cropping(to: rect)
    }

    /// Crops, scales and re-encodes the image. Re-encoding drops all metadata, including GPS location.
    static func export(_ job: ImageJob, to destination: URL) throws {
        let name = job.source.lastPathComponent
        guard let full = loadUpright(job.source) else { throw ProcessingError(errorDescription: "Couldn't read \(name).") }
        guard let cropped = crop(full, to: job.crop) else { throw ProcessingError(errorDescription: "Couldn't crop \(name).") }

        let width = max(1, min(job.maxWidth, cropped.width))
        let height = max(1, Int((CGFloat(cropped.height) * CGFloat(width) / CGFloat(cropped.width)).rounded()))
        guard let output = render(cropped, width: width, height: height, opaque: job.format == .jpeg) else {
            throw ProcessingError(errorDescription: "Couldn't resize \(name).")
        }

        guard let file = CGImageDestinationCreateWithURL(destination as CFURL, job.format.typeIdentifier as CFString, 1, nil) else {
            throw ProcessingError(errorDescription: "Couldn't create \(destination.lastPathComponent).")
        }
        var properties: [CFString: Any] = [:]
        if job.format == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = job.quality }
        CGImageDestinationAddImage(file, output, properties as CFDictionary)
        guard CGImageDestinationFinalize(file) else {
            throw ProcessingError(errorDescription: "Couldn't write \(destination.lastPathComponent).")
        }
    }

    private static func render(_ image: CGImage, width: Int, height: Int, opaque: Bool) -> CGImage? {
        let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? sRGB
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: alpha.rawValue)
                ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: alpha.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if opaque {
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(rect)
        }
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        return context.makeImage()
    }
}

enum AudioProcessing {
    /// Copies m4a files as they are and converts anything else to AAC in an m4a container.
    static func export(_ job: AudioJob, to destination: URL) async throws {
        if job.source.pathExtension.lowercased() == "m4a" {
            try FileManager.default.copyItem(at: job.source, to: destination)
            return
        }
        let asset = AVURLAsset(url: job.source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ProcessingError(errorDescription: "Can't convert \(job.source.lastPathComponent) to m4a.")
        }
        try await session.export(to: destination, as: .m4a)
    }
}
