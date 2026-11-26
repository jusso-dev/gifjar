import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Facts read from an image's header without decoding pixels.
nonisolated struct MediaInfo: Sendable, Equatable {
    var pixelWidth: Int
    var pixelHeight: Int
    var frameCount: Int
    /// Total loop duration in seconds (0 for stills).
    var duration: Double

    /// Reads type and geometry from raw bytes. Returns nil when the data isn't a decodable image.
    static func probe(_ data: Data) -> (UTType, MediaInfo)? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let typeID = CGImageSourceGetType(source) as String?,
            let type = UTType(typeID),
            CGImageSourceGetCount(source) > 0
        else { return nil }

        let count = CGImageSourceGetCount(source)
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        var height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        // Respect EXIF rotation so portrait photos lay out correctly.
        if let orientation = props[kCGImagePropertyOrientation] as? UInt32, (5...8).contains(orientation) {
            swap(&width, &height)
        }
        let delays = count > 1 ? FrameTiming.delays(for: source) : []
        return (type, MediaInfo(
            pixelWidth: width,
            pixelHeight: height,
            frameCount: count,
            duration: delays.reduce(0, +)
        ))
    }
}

/// Per-frame delays for GIF / APNG / WebP / HEICS, with browser-style clamping.
nonisolated enum FrameTiming {
    static func delays(for source: CGImageSource) -> [Double] {
        (0..<CGImageSourceGetCount(source)).map { delay(for: source, at: $0) }
    }

    static func delay(for source: CGImageSource, at index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return 0.1
        }
        let containers: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
        ]
        for (dictKey, unclamped, clamped) in containers {
            guard let dict = props[dictKey] as? [CFString: Any] else { continue }
            let value = (dict[unclamped] as? Double) ?? (dict[clamped] as? Double) ?? 0.1
            // Browsers treat ≤10ms as 100ms; many GIFs rely on it.
            return value <= 0.011 ? 0.1 : value
        }
        return 0.1
    }

    /// Decodes one frame at a bounded size, honouring EXIF orientation.
    static func downsample(_ source: CGImageSource, index: Int, maxPixel: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }
}

/// Owns the on-device copy of every original file.
nonisolated final class MediaStore: Sendable {
    static let shared = MediaStore()

    let directory: URL

    init(directory: URL? = nil) {
        let base = directory ?? URL.applicationSupportDirectory.appending(path: "Media", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Originals can be re-downloaded from R2, but keep them in backups for offline-first use.
        self.directory = base
    }

    func url(for id: UUID, type: UTType) -> URL {
        let ext = type.preferredFilenameExtension ?? "img"
        return directory.appending(path: "\(id.uuidString.lowercased()).\(ext)")
    }

    func exists(id: UUID, type: UTType) -> Bool {
        FileManager.default.fileExists(atPath: url(for: id, type: type).path(percentEncoded: false))
    }

    func write(_ data: Data, id: UUID, type: UTType) throws {
        try data.write(to: url(for: id, type: type), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func read(id: UUID, type: UTType) throws -> Data {
        try Data(contentsOf: url(for: id, type: type), options: .mappedIfSafe)
    }

    func delete(id: UUID, type: UTType) {
        try? FileManager.default.removeItem(at: url(for: id, type: type))
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
