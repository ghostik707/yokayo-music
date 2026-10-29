import SwiftUI

/// Картинка для сторис: строка песни на фоне обложки.
struct LyricCard: View {
    let line: String
    let song: Song
    let cover: UIImage?

    var body: some View {
        ZStack {
            if let cover {
                Image(uiImage: cover).resizable().scaledToFill().blur(radius: 60).scaleEffect(1.4)
            }
            LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 28) {
                    Group {
                        if let cover { Image(uiImage: cover).resizable().scaledToFill() } else { Color.gray }
                    }
                    .frame(width: 180, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(song.title).font(.system(size: 52, weight: .bold)).lineLimit(2)
                        Text(song.artist).font(.system(size: 40, weight: .medium)).opacity(0.7).lineLimit(1)
                    }
                }
                Spacer()
                Text("«\(line)»")
                    .font(.system(size: 92, weight: .heavy))
                    .lineSpacing(6)
                    .minimumScaleFactor(0.5)
                    .shadow(color: .white.opacity(0.25), radius: 20)
                Spacer()
                HStack(spacing: 18) {
                    Image("Star").resizable().scaledToFit().frame(width: 64, height: 64)
                    Text("Yokayo Music").font(.system(size: 40, weight: .heavy))
                }
                .opacity(0.9)
            }
            .foregroundStyle(.white)
            .padding(90)
        }
        .frame(width: 1080, height: 1920)
        .background(Color.black)
    }

    @MainActor
    static func render(line: String, song: Song) async -> UIImage? {
        var cover: UIImage?
        if let url = song.coverURL(600) { cover = await ImagePipeline.shared.image(url) }
        let r = ImageRenderer(content: LyricCard(line: line, song: song, cover: cover))
        r.scale = 1
        return r.uiImage
    }
}

/// Системное «Поделиться» для картинки.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct SharedImage: Identifiable { let id = UUID(); let image: UIImage }
