import Foundation
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import AppKit

enum TranscodeError: LocalizedError {
    case noVideoTrack
    case gifDecodeFailed
    case writerFailed(String)
    case readerFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "That file doesn't contain a video track."
        case .gifDecodeFailed: return "The GIF couldn't be decoded."
        case .writerFailed(let why): return "Encoding failed: \(why)"
        case .readerFailed(let why): return "Reading the source failed: \(why)"
        case .cancelled: return "Cancelled."
        }
    }
}

struct MediaInfo {
    var width: Int
    var height: Int
    var fps: Double
    var duration: Double
    var byteSize: Int64
}

struct TranscodeResult {
    var url: URL
    var width: Int
    var height: Int
    var duration: Double
    var byteSize: Int64
}

enum Transcoder {

    // MARK: - Sizing

    /// Scales a size down so its longest edge fits `maxDimension`, keeping aspect
    /// ratio and forcing even numbers (HEVC/H.264 require even dimensions).
    static func targetSize(width: Int, height: Int, maxDimension: CGFloat?) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (2, 2) }
        guard let maxDimension else { return (even(width), even(height)) }
        let longest = CGFloat(max(width, height))
        guard longest > maxDimension else { return (even(width), even(height)) }
        let scale = maxDimension / longest
        return (even(Int((CGFloat(width) * scale).rounded())),
                even(Int((CGFloat(height) * scale).rounded())))
    }

    private static func even(_ value: Int) -> Int { max(2, value - (value % 2)) }

    /// Bits per pixel per frame, chosen from the *output* height rather than the
    /// preset the user picked — a small frame needs more bits per pixel to look
    /// clean than a large one, regardless of what it was downscaled from.
    static func bitsPerPixel(forHeight height: Int) -> Double {
        switch height {
        case ..<800: return 0.095
        case ..<1200: return 0.085
        case ..<1600: return 0.080
        default: return 0.070
        }
    }

    // MARK: - Probing

    static func isGIF(_ url: URL) -> Bool {
        if let type = UTType(filenameExtension: url.pathExtension.lowercased()) {
            return type.conforms(to: .gif)
        }
        return url.pathExtension.lowercased() == "gif"
    }

    static func probe(_ url: URL) async throws -> MediaInfo {
        let byteSize = fileSize(url)
        if isGIF(url) { return try probeGIF(url, byteSize: byteSize) }

        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw TranscodeError.noVideoTrack
        }
        let duration = try await asset.load(.duration).seconds
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let nominal = Double(try await track.load(.nominalFrameRate))
        let oriented = natural.applying(transform)
        return MediaInfo(width: Int(abs(oriented.width).rounded()),
                         height: Int(abs(oriented.height).rounded()),
                         fps: nominal > 0 ? nominal : 30,
                         duration: duration.isFinite ? duration : 0,
                         byteSize: byteSize)
    }

    private static func probeGIF(_ url: URL, byteSize: Int64) throws -> MediaInfo {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw TranscodeError.gifDecodeFailed
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0, let first = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw TranscodeError.gifDecodeFailed
        }
        var total = 0.0
        for index in 0..<count { total += gifDelay(source, index) }
        let duration = max(total, 0.1)
        return MediaInfo(width: first.width,
                         height: first.height,
                         fps: Double(count) / duration,
                         duration: duration,
                         byteSize: byteSize)
    }

    static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - Entry point

    /// Produces a wallpaper-ready file at `destination`. GIFs are always converted
    /// to HEVC (AVFoundation can't play a GIF, and an "HD GIF" is usually 50-100x
    /// larger than the same footage in HEVC anyway).
    static func makeWallpaperFile(from source: URL,
                                  to destination: URL,
                                  quality: Quality,
                                  capFrameRate: Bool,
                                  progress: @escaping (Double) -> Void) async throws -> TranscodeResult {
        if isGIF(source) {
            return try await convertGIF(source: source, destination: destination, quality: quality, progress: progress)
        }
        if quality == .original {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
            let info = try await probe(destination)
            progress(1.0)
            return TranscodeResult(url: destination, width: info.width, height: info.height,
                                   duration: info.duration, byteSize: info.byteSize)
        }
        return try await compress(source: source, destination: destination,
                                  quality: quality, capFrameRate: capFrameRate, progress: progress)
    }

    // MARK: - Video -> smaller video

    private static func compress(source: URL,
                                 destination: URL,
                                 quality: Quality,
                                 capFrameRate: Bool,
                                 progress: @escaping (Double) -> Void) async throws -> TranscodeResult {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw TranscodeError.noVideoTrack
        }
        let info = try await probe(source)
        let duration = max(info.duration, 0.01)
        let target = targetSize(width: info.width, height: info.height, maxDimension: quality.maxDimension)
        let fps = capFrameRate ? min(info.fps, 30) : info.fps
        let targetRect = CGRect(x: 0, y: 0, width: CGFloat(target.width), height: CGFloat(target.height))

        // A CoreImage video composition is the simplest way to get both correct
        // orientation handling and an arbitrary output size in one pass.
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let src = request.sourceImage
            let extent = src.extent
            guard extent.width > 0, extent.height > 0 else {
                request.finish(with: src, context: nil)
                return
            }
            let moved = src.transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
            let scaled = moved.transformed(by: CGAffineTransform(scaleX: targetRect.width / extent.width,
                                                                y: targetRect.height / extent.height))
            request.finish(with: scaled.cropped(to: targetRect), context: nil)
        }
        composition.renderSize = targetRect.size
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, Int32(fps.rounded()))))

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: [track],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        output.videoComposition = composition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw TranscodeError.readerFailed("unsupported source") }
        reader.add(output)

        let writer = try makeWriter(at: destination, target: target, fps: fps)
        let input = writer.inputs[0]

        guard writer.startWriting() else {
            throw TranscodeError.writerFailed(writer.error?.localizedDescription ?? "could not start")
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            throw TranscodeError.readerFailed(reader.error?.localizedDescription ?? "could not start")
        }

        try await pump(input: input, writer: writer, reader: reader, duration: duration, progress: progress) {
            guard let sample = output.copyNextSampleBuffer() else { return .finished }
            return .append(sample)
        }

        let outInfo = try await probe(destination)
        return TranscodeResult(url: destination, width: outInfo.width, height: outInfo.height,
                               duration: outInfo.duration, byteSize: outInfo.byteSize)
    }

    // MARK: - GIF -> video

    private static func convertGIF(source: URL,
                                   destination: URL,
                                   quality: Quality,
                                   progress: @escaping (Double) -> Void) async throws -> TranscodeResult {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw TranscodeError.gifDecodeFailed
        }
        let frameCount = CGImageSourceGetCount(imageSource)
        guard frameCount > 0, let firstFrame = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw TranscodeError.gifDecodeFailed
        }

        var delays: [Double] = []
        for index in 0..<frameCount { delays.append(gifDelay(imageSource, index)) }
        let duration = max(delays.reduce(0, +), 0.1)
        let fps = min(Double(frameCount) / duration, 60)
        let target = targetSize(width: firstFrame.width, height: firstFrame.height, maxDimension: quality.maxDimension)

        let writer = try makeWriter(at: destination, target: target, fps: fps)
        let input = writer.inputs[0]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: target.width,
                kCVPixelBufferHeightKey as String: target.height,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
        )

        guard writer.startWriting() else {
            throw TranscodeError.writerFailed(writer.error?.localizedDescription ?? "could not start")
        }
        writer.startSession(atSourceTime: .zero)

        let timescale: CMTimeScale = 1000
        var frameIndex = 0
        var elapsed = 0.0

        try await pump(input: input, writer: writer, reader: nil, duration: duration, progress: progress) {
            guard frameIndex < frameCount else { return .finished }
            defer {
                elapsed += delays[frameIndex]
                frameIndex += 1
            }
            guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, frameIndex, nil),
                  let pool = adaptor.pixelBufferPool,
                  let buffer = makePixelBuffer(from: cgImage, pool: pool, target: target)
            else { return .failed("frame \(frameIndex) could not be decoded") }

            let time = CMTime(seconds: elapsed, preferredTimescale: timescale)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                return .failed("frame \(frameIndex) could not be encoded")
            }
            progress(min(elapsed / duration, 0.99))
            return .appendedDirectly
        }

        let outInfo = try await probe(destination)
        return TranscodeResult(url: destination, width: outInfo.width, height: outInfo.height,
                               duration: outInfo.duration, byteSize: outInfo.byteSize)
    }

    private static func makePixelBuffer(from image: CGImage,
                                        pool: CVPixelBufferPool,
                                        target: (width: Int, height: Int)) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
              let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: target.width,
            height: target.height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        let canvas = CGRect(x: 0, y: 0, width: target.width, height: target.height)
        // GIFs can carry transparency; flatten onto black so it doesn't come out grey.
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(canvas)

        let scale = max(canvas.width / CGFloat(image.width), canvas.height / CGFloat(image.height))
        let drawn = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.draw(image, in: CGRect(x: (canvas.width - drawn.width) / 2,
                                       y: (canvas.height - drawn.height) / 2,
                                       width: drawn.width,
                                       height: drawn.height))
        return pixelBuffer
    }

    private static func gifDelay(_ source: CGImageSource, _ index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return 0.1 }
        let delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gif[kCGImagePropertyGIFDelayTime] as? Double)
            ?? 0.1
        // Browsers clamp near-zero delays to 100ms; match that so fast GIFs
        // don't play back at 100fps.
        return delay < 0.011 ? 0.1 : delay
    }

    // MARK: - Shared writer plumbing

    private static func makeWriter(at destination: URL,
                                   target: (width: Int, height: Int),
                                   fps: Double) throws -> AVAssetWriter {
        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)

        let pixelsPerSecond = Double(target.width * target.height) * max(fps, 1)
        let bitrate = Int(max(pixelsPerSecond * bitsPerPixel(forHeight: target.height), 400_000))

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: target.width,
            AVVideoHeightKey: target.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: Int(max(fps.rounded(), 1)),
                AVVideoMaxKeyFrameIntervalDurationKey: 2.0
            ] as [String: Any]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw TranscodeError.writerFailed("HEVC encoder unavailable") }
        writer.add(input)
        return writer
    }

    /// One step of work handed back by the producer closure.
    ///
    /// This is deliberately an enum rather than a nested optional: with a
    /// `CMSampleBuffer??` return type, Swift silently promotes the reader's
    /// end-of-stream `nil` into `.some(nil)` and the pump never terminates.
    enum PumpStep {
        /// Append this buffer to the writer input.
        case append(CMSampleBuffer)
        /// The closure already appended (pixel-buffer adaptor path).
        case appendedDirectly
        /// No more frames.
        case finished
        case failed(String)
    }

    /// Drives an `AVAssetWriterInput` until `next` reports `.finished`.
    private static func pump(input: AVAssetWriterInput,
                             writer: AVAssetWriter,
                             reader: AVAssetReader?,
                             duration: Double,
                             progress: @escaping (Double) -> Void,
                             next: @escaping () -> PumpStep) async throws {
        let queue = DispatchQueue(label: "com.octoberwip.loopwall.transcode")
        var isDone = false

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Callbacks are serialised on `queue`, so `isDone` needs no lock.
                input.requestMediaDataWhenReady(on: queue) {
                    guard !isDone else { return }

                    func fail(_ error: Error) {
                        isDone = true
                        reader?.cancelReading()
                        writer.cancelWriting()
                        continuation.resume(throwing: error)
                    }

                    while input.isReadyForMoreMediaData {
                        if Task.isCancelled {
                            fail(TranscodeError.cancelled)
                            return
                        }

                        switch next() {
                        case .append(let sample):
                            let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                            if seconds.isFinite, duration > 0 {
                                progress(min(max(seconds / duration, 0), 0.99))
                            }
                            if !input.append(sample) {
                                fail(TranscodeError.writerFailed(
                                    writer.error?.localizedDescription ?? "append failed"))
                                return
                            }

                        case .appendedDirectly:
                            continue

                        case .failed(let why):
                            fail(TranscodeError.writerFailed(why))
                            return

                        case .finished:
                            isDone = true
                            input.markAsFinished()
                            if let reader, reader.status == .failed {
                                writer.cancelWriting()
                                continuation.resume(throwing: TranscodeError.readerFailed(
                                    reader.error?.localizedDescription ?? "unknown"))
                                return
                            }
                            writer.finishWriting {
                                if writer.status == .completed {
                                    progress(1.0)
                                    continuation.resume()
                                } else {
                                    continuation.resume(throwing: TranscodeError.writerFailed(
                                        writer.error?.localizedDescription ?? "unknown"))
                                }
                            }
                            return
                        }
                    }
                }
            }
        } onCancel: {
            reader?.cancelReading()
        }
    }
}
