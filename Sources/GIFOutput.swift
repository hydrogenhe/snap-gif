import Foundation
import ImageIO

struct GIFRecordingSettings {
    static let frameRates = [4, 8, 12, 16, 30, 60]
    static let resolutions = [480, 720, 960]
    static let frameRateKey = "gifFrameRate"
    static let resolutionKey = "gifResolution"

    let fps: Int
    let longestEdge: Int

    init(defaults: UserDefaults = .standard) {
        let rate = defaults.integer(forKey: Self.frameRateKey)
        let resolution = defaults.integer(forKey: Self.resolutionKey)
        fps = Self.frameRates.contains(rate) ? rate : 8
        longestEdge = Self.resolutions.contains(resolution) ? resolution : 720
    }

    static func label(for fps: Int) -> String {
        "\(fps) fps"
    }

    var frameInterval: TimeInterval { 1 / Double(fps) }

    func outputScale(for region: CGRect, displayScale: CGFloat) -> CGFloat {
        min(displayScale, CGFloat(longestEdge) / max(region.width, region.height))
    }
}

struct GIFOutputDetails {
    let dimensions: CGSize
    let frameCount: Int
    let byteCount: Int64

    init?(file: URL) {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        self.init(source: source, byteCount: Int64(size))
    }

    init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        self.init(source: source, byteCount: Int64(data.count))
    }

    private init?(source: CGImageSource, byteCount: Int64) {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        dimensions = CGSize(width: width, height: height)
        frameCount = CGImageSourceGetCount(source)
        self.byteCount = byteCount
    }

    var summary: String {
        let storage = ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
        return "\(Int(dimensions.width)) × \(Int(dimensions.height)) · \(frameCount) 帧 · \(storage)"
    }
}
