import SwiftUI
import YMAPI
import CryptoKit

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: Double?
    let text: String
}

/// Тексты песен из Яндекса: синхронные (LRC) или обычные.
enum LyricsLoader {
    private static var cache: [String: [LyricLine]] = [:]

    @MainActor
    static func load(_ song: Song) async -> [LyricLine]? {
        guard case .yandex(let id) = song.source else { return nil }
        if let c = cache[id] { return c }
        let numeric = String(id.split(separator: ":").first ?? Substring(id))
        for format in ["LRC", "TEXT"] {
            guard let link = await downloadURL(trackId: numeric, format: format),
                  let (data, _) = try? await URLSession.shared.data(from: link),
                  let text = String(data: data, encoding: .utf8), !text.isEmpty else { continue }
            let lines = format == "LRC" ? parseLRC(text) : text.components(separatedBy: .newlines).enumerated().map { LyricLine(id: $0, time: nil, text: $1) }
            if !lines.isEmpty { cache[id] = lines; return lines }
        }
        return nil
    }

    /// GET /tracks/{id}/lyrics с подписью HMAC-SHA256(id + timestamp), как в официальных клиентах.
    private static func downloadURL(trackId: String, format: String) async -> URL? {
        guard let token = Keychain.get("token") else { return nil }
        let ts = String(Int(Date().timeIntervalSince1970))
        let mac = HMAC<SHA256>.authenticationCode(for: Data((trackId + ts).utf8), using: SymmetricKey(data: Data("p93jhgh689SBReK6ghtw62".utf8)))
        let sign = Data(mac).base64EncodedString()
        var comps = URLComponents(string: YMConstants.apiBasePath + "tracks/\(trackId)/lyrics")!
        comps.queryItems = [URLQueryItem(name: "format", value: format), URLQueryItem(name: "timeStamp", value: ts), URLQueryItem(name: "sign", value: sign)]
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("OAuth " + token, forHTTPHeaderField: "Authorization")
        req.setValue(YMConstants.xYmClient, forHTTPHeaderField: "X-Yandex-Music-Client")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let link = result["downloadUrl"] as? String else { return nil }
        return URL(string: link)
    }

    static func parseLRC(_ text: String) -> [LyricLine] {
        var out: [LyricLine] = []
        let re = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        for raw in text.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let matches = re.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let lyric = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            for m in matches {
                let t = (Double(ns.substring(with: m.range(at: 1))) ?? 0) * 60 + (Double(ns.substring(with: m.range(at: 2))) ?? 0)
                out.append(LyricLine(id: 0, time: t, text: lyric))
            }
        }
        return out.sorted { ($0.time ?? 0) < ($1.time ?? 0) }.enumerated().map { LyricLine(id: $0, time: $1.time, text: $1.text) }
    }
}

/// Время строк, когда у Яндекса нет синхронного текста: раскладываем по длине трека.
enum LyricsTiming {
    static func estimate(_ lines: [LyricLine], duration: Double, analysis: TrackAnalysis?) -> [LyricLine] {
        guard duration > 0, !lines.isEmpty else { return lines }
        let start = max(analysis?.mixIn ?? 0, duration * 0.06)
        let end = min(analysis?.lastSound ?? duration, duration) - duration * 0.05
        let weights = lines.map { l -> Double in l.text.isEmpty ? 2.5 : 3 + Double(l.text.count) * 0.12 }
        let total = weights.reduce(0, +)
        var t = start
        return lines.enumerated().map { i, l in
            defer { t += (end - start) * weights[i] / total }
            return LyricLine(id: l.id, time: t, text: l.text)
        }
    }
}

/// Экран текста как в Apple Music: подсветка по словам, крупная активная строка,
/// точки в проигрышах, автопрокрутка, перемотка по нажатию.
struct LyricsView: View {
    @EnvironmentObject private var player: Player
    @State private var lines: [LyricLine]?
    @State private var approximate = false
    @State private var shareItem: SharedImage?
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let lines, !lines.isEmpty {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !player.isPlaying)) { _ in
                    content(lines, now: player.livePosition + 0.15)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "quote.bubble").font(.system(size: 40)).foregroundStyle(.white.opacity(0.5))
                    Text("Текста для этого трека нет").foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: player.current?.id) { await load() }
        .sheet(item: $shareItem) { item in ShareSheet(items: [item.image]).presentationDetents([.medium, .large]) }
        .onChange(of: player.activeDeck.analysis?.bpm) { _, _ in
            if approximate, let l = lines { lines = LyricsTiming.estimate(l, duration: player.duration, analysis: player.activeDeck.analysis) }
        }
    }

    private func load() async {
        loading = true; lines = nil; approximate = false
        guard let s = player.current, var l = await LyricsLoader.load(s) else { loading = false; return }
        if l.first?.time == nil {
            approximate = true
            l = LyricsTiming.estimate(l, duration: player.duration, analysis: player.activeDeck.analysis)
        }
        lines = l
        loading = false
    }

    private func content(_ lines: [LyricLine], now: Double) -> some View {
        let active = lines.lastIndex { ($0.time ?? 0) <= now }
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    if approximate {
                        Label("Синхронизация примерная", systemImage: "wand.and.stars")
                            .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.5))
                    }
                    if let first = lines.first?.time, first > 5, (active == nil) {
                        BreathingDots(progress: min(1, now / first)).id(-1)
                    }
                    ForEach(lines) { line in
                        let i = line.id
                        let start = line.time ?? 0
                        let next = i + 1 < lines.count ? (lines[i + 1].time ?? start + 4) : player.duration
                        let isActive = i == active
                        let distance = active.map { abs(i - $0) } ?? 3
                        VStack(alignment: .leading, spacing: 18) {
                            if line.text.isEmpty {
                                if isActive, next - start > 5 {
                                    BreathingDots(progress: min(1, max(0, (now - start) / (next - start))))
                                } else { Color.clear.frame(height: 6) }
                            } else {
                                KaraokeLine(text: line.text, start: start, end: next, now: now, active: isActive)
                                    .blur(radius: isActive ? 0 : min(2.2, Double(distance) * 0.7))
                                    .opacity(isActive ? 1 : max(0.25, 0.55 - Double(distance) * 0.08))
                                    .scaleEffect(isActive ? 1 : 0.94, anchor: .leading)
                            }
                        }
                        .id(i)
                        .contentShape(Rectangle())
                        .onTapGesture { player.seek(to: start); if !player.isPlaying { player.resume() } }
                        .contextMenu {
                            if !line.text.isEmpty, let song = player.current {
                                Button {
                                    Task { if let img = await LyricCard.render(line: line.text, song: song) { shareItem = SharedImage(image: img) } }
                                } label: { Label("Поделиться строкой", systemImage: "square.and.arrow.up") }
                                Button { UIPasteboard.general.string = line.text } label: { Label("Скопировать", systemImage: "doc.on.doc") }
                            }
                        }
                        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: isActive)
                    }
                    Spacer(minLength: 260)
                }
                .padding(.horizontal, 28).padding(.top, 24)
            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.1),
                                         .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .onChange(of: active) { _, i in
                guard let i else { return }
                withAnimation(.spring(response: 0.7, dampingFraction: 0.86)) { proxy.scrollTo(i, anchor: UnitPoint(x: 0, y: 0.28)) }
            }
            .onAppear { if let active { proxy.scrollTo(active, anchor: UnitPoint(x: 0, y: 0.28)) } }
        }
    }
}

/// Строка с подсветкой по словам: пропетые слова — белые, текущее — наливается светом.
struct KaraokeLine: View {
    let text: String
    let start: Double
    let end: Double
    let now: Double
    let active: Bool

    var body: some View {
        let words = text.split(separator: " ").map(String.init)
        let weights = words.map { Double($0.count) + 1.5 }
        let total = weights.reduce(0, +)
        let span = max(0.5, min(end - start, Double(words.count) * 0.75 + 1.2))   // петь строку быстрее, чем пауза до следующей
        var acc = 0.0
        let spans: [(Double, Double)] = weights.map { w in
            defer { acc += w }
            return (start + span * acc / total, start + span * (acc + w) / total)
        }
        return WordFlow(spacing: 8, lineSpacing: 4) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                let p = active ? min(1, max(0, (now - spans[i].0) / max(0.05, spans[i].1 - spans[i].0))) : (now >= end ? 1 : 0)
                Text(w)
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.32))
                    .overlay(alignment: .leading) {
                        Text(w)
                            .font(.system(size: 30, weight: .heavy))
                            .foregroundStyle(.white)
                            .mask(alignment: .leading) {
                                GeometryReader { g in
                                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: max(0, p - 0.08)),
                                                           .init(color: .clear, location: min(1, p + 0.08))],
                                                   startPoint: .leading, endPoint: .trailing)
                                        .frame(width: g.size.width * 1.2)
                                }
                            }
                            .shadow(color: active ? .white.opacity(0.55 * p) : .clear, radius: 8)
                    }
                    .offset(y: active && p > 0 && p < 1 ? -2 : 0)
            }
        }
    }
}

/// Три «дышащие» точки в проигрыше.
struct BreathingDots: View {
    var progress: Double
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 10) {
                ForEach(0..<3) { i in
                    let lit = progress > Double(i) / 3
                    Circle().fill(.white.opacity(lit ? 0.95 : 0.3))
                        .frame(width: 12, height: 12)
                        .scaleEffect(1 + 0.18 * sin(t * 3 + Double(i) * 0.6))
                }
            }
            .padding(.vertical, 6)
        }
    }
}

/// Перенос слов по строкам.
struct WordFlow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, width: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxW { y += rowH + lineSpacing; x = 0; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height); width = max(width, x - spacing)
        }
        return CGSize(width: min(width, maxW), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { y += rowH + lineSpacing; x = bounds.minX; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}
