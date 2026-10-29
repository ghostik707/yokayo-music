import UIKit
import SwiftUI

/// Загрузка и кэш картинок.
actor ImagePipeline {
    static let shared = ImagePipeline()
    private nonisolated(unsafe) let cache = NSCache<NSURL, UIImage>()
    private var tasks: [URL: Task<UIImage?, Never>] = [:]
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 30 << 20, diskCapacity: 300 << 20)
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: cfg)
    }()

    nonisolated func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    func image(_ url: URL) async -> UIImage? {
        if let img = cache.object(forKey: url as NSURL) { return img }
        if let t = tasks[url] { return await t.value }
        let t = Task<UIImage?, Never> {
            let data: Data?
            if url.isFileURL { data = try? Data(contentsOf: url) }
            else { data = try? await session.data(from: url).0 }
            guard let data, let img = UIImage(data: data) else { return nil }
            return await img.byPreparingForDisplay() ?? img
        }
        tasks[url] = t
        let img = await t.value
        tasks[url] = nil
        if let img { cache.setObject(img, forKey: url as NSURL) }
        return img
    }
}

/// Обложка с плавным появлением и заглушкой.
struct CoverView: View {
    let url: URL?
    var cornerRadius: CGFloat = 8
    var symbol: String = "music.note"
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
            } else {
                LinearGradient(colors: [Color(.systemGray5), Color(.systemGray4)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay {
                        Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
                    }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .task(id: url) {
            guard let url else { image = nil; return }
            if let c = ImagePipeline.shared.cached(url) { image = c; return }
            let img = await ImagePipeline.shared.image(url)
            withAnimation(.easeOut(duration: 0.25)) { image = img }
        }
    }
}

/// Цвета обложки для живого фона плеера (сетка 3×3).
enum ArtworkPalette {
    static func colors(_ image: UIImage) -> [Color] {
        let size = 3
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let cg = image.cgImage,
              let ctx = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return Array(repeating: .gray, count: 9) }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
        return (0..<9).map { i in
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(red: CGFloat(pixels[i * 4]) / 255, green: CGFloat(pixels[i * 4 + 1]) / 255,
                    blue: CGFloat(pixels[i * 4 + 2]) / 255, alpha: 1).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            // насыщеннее и чуть темнее — как фон в Apple Music
            return Color(hue: h, saturation: min(1, s * 1.25 + 0.05), brightness: min(0.85, max(0.18, b * 0.85)))
        }
    }
}
