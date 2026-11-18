import Foundation
import AppKit
import ImageIO

public enum ImageDownsampler {
    /// Reads image dimensions from file header without decoding pixel data into RAM.
    public static func pixelDimensions(url: URL) -> NSSize? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              w > 0, h > 0 else {
            return nil
        }
        return NSSize(width: w, height: h)
    }

    /// Downsample an image from a file URL to a target maximum pixel dimension.
    /// This decodes only the required resolution into memory, avoiding large uncompressed bitmaps.
    public static func downsample(url: URL, maxPixelSize: CGFloat) -> NSImage? {
        autoreleasepool {
            let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, imageSourceOptions) else {
                return nil
            }
            return createThumbnail(from: imageSource, maxPixelSize: maxPixelSize)
        }
    }

    /// Downsample an image from in-memory Data to a target maximum pixel dimension.
    public static func downsample(data: Data, maxPixelSize: CGFloat) -> NSImage? {
        autoreleasepool {
            let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let imageSource = CGImageSourceCreateWithData(data as CFData, imageSourceOptions) else {
                return nil
            }
            return createThumbnail(from: imageSource, maxPixelSize: maxPixelSize)
        }
    }

    private static func createThumbnail(from imageSource: CGImageSource, maxPixelSize: CGFloat) -> NSImage? {
        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 32)
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions as CFDictionary) else {
            return nil
        }
        let w = thumbnail.width
        let h = thumbnail.height
        guard w > 0, h > 0 else { return nil }
        let size = NSSize(width: CGFloat(w), height: CGFloat(h))

        // Always copy into a compact 8-bit-per-channel RGBA NSBitmapImageRep so 16-bit/channel ICNS/PNGs
        // and ImageIO DefaultPurgeableMallocZone backing stores are released immediately.
        if let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: w,
            pixelsHigh: h,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: w * 4,
            bitsPerPixel: 32
        ), let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext {
            ctx.interpolationQuality = .high
            ctx.draw(thumbnail, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
            rep.size = size
            let img = NSImage(size: size)
            img.addRepresentation(rep)
            return img
        }

        let rep = NSBitmapImageRep(cgImage: thumbnail)
        let img = NSImage(size: size)
        img.addRepresentation(rep)
        return img
    }
}
