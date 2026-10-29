import AVFoundation
import UIKit

/// Делает из квадратной обложки вертикальный ролик 3:4 с медленным «наездом камеры».
/// iOS 26 показывает такую обложку на весь экран блокировки — как в Apple Music.
enum ArtworkMotion {
    static let size = CGSize(width: 720, height: 960)
    private static let fps: Int32 = 24
    private static let seconds = 8.0

    private static var dir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("LockArtwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Кадр 3:4: обложка заполняет весь кадр (края по бокам обрезаются).
    static func tallImage(_ image: UIImage, size: CGSize = size, zoom: CGFloat = 1) -> UIImage {
        UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { _ in
            let side = max(size.width, size.height) * zoom
            image.draw(in: CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side))
        }
    }

    static func video(id: String, image: UIImage) async -> URL? {
        let url = dir.appendingPathComponent(AudioFiles.safeName(id) + ".mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        return await Task.detached(priority: .utility) { () -> URL? in
            let tmp = url.deletingPathExtension().appendingPathExtension("tmp.mp4")
            try? FileManager.default.removeItem(at: tmp)
            guard render(image: image, to: tmp) else { return nil }
            try? FileManager.default.moveItem(at: tmp, to: url)
            return url
        }.value
    }

    private static func render(image: UIImage, to url: URL) -> Bool {
        guard let cg = image.cgImage,
              let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }
        let w = Int(size.width), h = Int(size.height)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_500_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frames = Int(seconds * Double(fps))
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            guard let pool = adaptor.pixelBufferPool else { return false }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { return false }
            CVPixelBufferLockBaseAddress(pb, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                // плавный бесшовный цикл: приближение и обратно, лёгкий сдвиг
                let t = Double(i) / Double(frames) * 2 * .pi
                let zoom = 1.04 + 0.04 * sin(t)
                let side = CGFloat(h) * zoom
                let dx = CGFloat(sin(t) * 18), dy = CGFloat(cos(t) * 10)
                ctx.interpolationQuality = .high
                ctx.draw(cg, in: CGRect(x: (CGFloat(w) - side) / 2 + dx, y: (CGFloat(h) - side) / 2 + dy, width: side, height: side))
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return writer.status == .completed
    }
}
