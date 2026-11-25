import CoreGraphics
import CoreVideo
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Keeps the in-memory GIF encoder from retaining gigabytes of raw frames at 60 fps.
struct HighRateCaptureBudget {
    let frameLimit: Int
    let duration: TimeInterval

    init(width: Int, height: Int, fps: Int) {
        // Account for 64-byte row padding in BGRA images.
        let bytesPerFrame = ((width * 4 + 63) / 64 * 64) * height
        frameLimit = min(fps * 15, max(2, (384 * 1024 * 1024) / bytesPerFrame))
        duration = Double(frameLimit) / Double(fps)
    }
}

final class HighRateCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "snap-gif.high-rate", qos: .userInitiated)
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private let frameLimit: Int
    private var firstTimestamp: CMTime?
    private var firstArrival: TimeInterval?
    private var frames: [Frame] = []
    private var streamError: Error?

    init(frameLimit: Int) {
        self.frameLimit = frameLimit
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, frames.count < frameLimit, buffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[SCStreamFrameInfo.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let pixels = buffer.imageBuffer else { return }
        let timestamp = buffer.presentationTimeStamp
        guard timestamp.isNumeric else { return }
        let time = CMTimeSubtract(timestamp, firstTimestamp ?? timestamp).seconds
        guard time.isFinite, time >= 0, frames.last.map({ $0.time < time }) ?? true else { return }
        // Copy out of the capture pool before retaining a frame for GIF encoding.
        guard let image = copyImage(from: pixels) else { return }
        if firstTimestamp == nil {
            firstTimestamp = timestamp
            firstArrival = ProcessInfo.processInfo.systemUptime
        }
        frames.append(Frame(image: image, time: time))
    }

    private func copyImage(from pixels: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return nil }
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        let data = Data(bytes: base, count: stride * height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            .union(.byteOrder32Little)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: stride, space: colorSpace, bitmapInfo: bitmapInfo,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        queue.async { self.streamError = error }
    }

    var didFinish: Bool {
        queue.sync { frames.count >= frameLimit || streamError != nil }
    }

    func finish(at stopTime: TimeInterval) throws -> ([Frame], TimeInterval) {
        try queue.sync {
            guard let firstArrival else { throw streamError ?? CaptureError.encoding }
            let end = max(0, stopTime - firstArrival)
            let captured = frames.prefix { $0.time <= end }
            return (captured.isEmpty ? Array(frames.prefix(1)) : Array(captured), end)
        }
    }
}
