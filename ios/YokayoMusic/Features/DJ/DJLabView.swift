import SwiftUI

/// DJ-лаборатория: выбери два трека — ИИ соберёт и сыграет переход.
struct DJLabView: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var settings: AppSettings
    @State private var trackA: Song?
    @State private var trackB: Song?
    @State private var picking: Slot?
    @State private var finding = false
    @State private var findNote: String?
    @State private var started = false
    @State private var variant = 0

    enum Slot: Identifiable { case a, b; var id: Int { self == .a ? 0 : 1 } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                HStack(spacing: 12) {
                    slot(.a, trackA)
                    Image(systemName: "arrow.right").font(.title3.weight(.bold)).foregroundStyle(Color.neon)
                    slot(.b, trackB)
                }
                .padding(.horizontal, 20)

                Button { Task { await findPair() } } label: {
                    HStack(spacing: 10) {
                        if finding { ProgressView().tint(Color.neon) } else { Image(systemName: "wand.and.stars") }
                        Text(finding ? (findNote ?? "ИИ ищет пару…") : "Подобрать пару — ИИ")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain).disabled(finding)
                .padding(.horizontal, 20)

                HStack(spacing: 12) {
                    Button { play(newVariant: false) } label: {
                        Label("Сыграть переход", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity).frame(height: 56)
                            .background(LinearGradient(colors: [.neon, .neonDeep], startPoint: .leading, endPoint: .trailing),
                                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .foregroundStyle(.white)
                            .shadow(color: Color.neon.opacity(0.5), radius: 16)
                    }
                    .buttonStyle(PressScale())
                    if started {
                        Button { play(newVariant: true) } label: {
                            Image(systemName: "dice.fill").font(.title2)
                                .frame(width: 56, height: 56)
                                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(PressScale())
                        .accessibilityLabel("Другой вариант")
                    }
                }
                .disabled(trackA == nil || trackB == nil || player.isLoading)
                .opacity(trackA == nil || trackB == nil ? 0.5 : 1)
                .padding(.horizontal, 20)
                if started {
                    Text("🎲 — другой вариант: лучший → короткий фильтр-микс → уход в эхо.")
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 20)
                }

                if started || player.djStatus != nil { LiveDecks().padding(.horizontal, 20) }
            }
            .padding(.vertical, 16)
        }
        .yokayoBackground()
        .navigationTitle("DJ-лаборатория")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $picking) { slot in
            TrackPickerSheet { song in
                if slot == .a { trackA = song } else { trackB = song }
            }
        }
        .onAppear {
            if trackA == nil { trackA = player.current.flatMap { $0.isLocal ? nil : $0 } }
            if trackB == nil { trackB = player.upNext.first { !$0.isLocal } }
        }
    }

    private func play(newVariant: Bool) {
        guard let a = trackA, let b = trackB else { return }
        if newVariant { variant += 1 }
        started = true
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        Task { await player.playDemo(a, b, variant: variant) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "brain.head.profile.fill").font(.system(size: 38))
                .foregroundStyle(LinearGradient(colors: [.neon, .neonDeep], startPoint: .top, endPoint: .bottom))
                .shadow(color: Color.neon.opacity(0.6), radius: 10)
            VStack(alignment: .leading, spacing: 6) {
                Text(settings.djMode == "classic" ? "Классический переход" : "ИИ-диджей").font(.title2.bold())
                Text("Выбери два трека. ИИ разберёт их — темп, сетку битов, фразы, интро, дроп, аутро и тональность — и сведёт так, чтобы дроп второго лёг ровно на фразу первого.")
                    .font(.subheadline).foregroundStyle(.secondary)

            }
        }
        .padding(.horizontal, 20)
    }

    private func slot(_ s: Slot, _ song: Song?) -> some View {
        Button { picking = s } label: {
            VStack(spacing: 8) {
                ZStack {
                    if let song { CoverView(url: song.coverURL(300), cornerRadius: 14) }
                    else {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06))
                            .overlay(Image(systemName: "plus").font(.title.weight(.semibold)).foregroundStyle(Color.neon))
                            .aspectRatio(1, contentMode: .fit)
                    }
                    Text(s == .a ? "A" : "B").font(.caption.weight(.heavy)).padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(6)
                }
                Text(song?.title ?? "Выбрать трек").font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(song?.artist ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    /// ИИ слушает до 8 треков из «Мне нравится» (или чарта) и берёт пару с ближайшим темпом.
    private func findPair() async {
        finding = true
        defer { finding = false; findNote = nil }
        var pool = ((try? await API.likedSongs()) ?? []).prefix(8).map { $0 }
        if pool.count < 4 { pool += ((try? await API.chart()) ?? []).prefix(8 - pool.count) }
        var analyzed: [(Song, TrackAnalysis)] = []
        for (i, s) in pool.enumerated() {
            findNote = "Слушаю трек \(i + 1) из \(pool.count)…"
            guard let url = try? await AudioFiles.shared.file(for: s, maxBitrate: 192),
                  let a = await BeatAnalyzer.analyze(id: s.id, file: url) else { continue }
            analyzed.append((s, a))
        }
        var best: (Song, Song, Double)?
        for i in analyzed.indices { for j in analyzed.indices where i != j && analyzed[i].0.artist != analyzed[j].0.artist {
            let (a, b) = (analyzed[i].1, analyzed[j].1)
            let r = [1.0, 2, 0.5].map { abs(a.bpm / (b.bpm * $0) - 1) }.min()!
            let score = r + 0.1 * Double(abs((a.energy.last ?? 0.5) - (b.energy.first ?? 0.5)))
            if best == nil || score < best!.2 { best = (analyzed[i].0, analyzed[j].0, score) }
        } }
        if let best { trackA = best.0; trackB = best.1; variant = 0; player.toast = "Пара найдена" }
        else { player.toast = "Не нашёл пару — выбери треки вручную" }
    }
}

/// Живая панель: две деки, кроссфейдер, фазы битов, фильтры и решение робота.
struct LiveDecks: View {
    @EnvironmentObject private var player: Player

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !player.isPlaying)) { _ in
            let s = player.djSnapshot()
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(s.plan?.headline ?? "Ждём переход", systemImage: s.progress > 0 ? "waveform" : "hourglass")
                        .font(.headline).foregroundStyle(Color.neon).lineLimit(1)
                    Spacer()
                    if s.progress > 0 { Text("\(Int(s.progress * 100))%").font(.subheadline.monospacedDigit().weight(.semibold)) }
                }
                ProgressView(value: s.progress).tint(Color.neon)
                if let m = s.plan {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(m.steps.enumerated()), id: \.offset) { i, step in
                            let reached = s.progress >= (i == 0 ? 0.001 : i == 1 ? m.swapAt : min(1, m.swapAt + 0.05))
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: reached ? "checkmark.circle.fill" : "circle").foregroundStyle(reached ? Color.neon : .secondary)
                                Text(step).font(.caption).foregroundStyle(reached ? .primary : .secondary)
                            }
                        }
                    }
                }
                deck("A", s.a)
                crossfader(s.crossfade)
                if let b = s.b { deck("B", b) }
                if let r = player.djDecision {
                    Label(r, systemImage: "brain").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.neon.opacity(0.25)))
        }
    }

    private func deck(_ name: String, _ d: DJSnapshot.DeckInfo) -> some View {
        HStack(spacing: 12) {
            CoverView(url: d.cover, cornerRadius: 8).frame(width: 52, height: 52)
                .opacity(0.4 + 0.6 * min(1, d.level))
            VStack(alignment: .leading, spacing: 3) {
                Text("\(name) · \(d.title)").font(.subheadline.weight(.semibold)).lineLimit(1)
                HStack(spacing: 10) {
                    if let bpm = d.bpm { Text("\(Int(bpm.rounded())) BPM").monospacedDigit() }
                    if let k = d.key { Text(k).foregroundStyle(.secondary) }
                    Text(String(format: "%+.1f%%", (d.rate - 1) * 100)).monospacedDigit().foregroundStyle(.secondary)
                    if let f = d.filter { Text(f).foregroundStyle(Color.neon) }
                }
                .font(.caption)
            }
            Spacer()
            // фаза доли: четыре точки, текущая горит
            if let ph = d.phase {
                HStack(spacing: 4) {
                    ForEach(0..<4) { i in
                        Circle().fill(Int(ph * 4) == i ? Color.neon : Color.white.opacity(0.18)).frame(width: 7, height: 7)
                    }
                }
            }
        }
    }

    private func crossfader(_ x: Double) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1)).frame(height: 6)
                Capsule().fill(Color.neon).frame(width: 34, height: 18)
                    .offset(x: (g.size.width - 34) * x)
                    .shadow(color: Color.neon.opacity(0.7), radius: 6)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 22)
        .overlay(alignment: .leading) { Text("A").font(.caption2.weight(.heavy)).offset(y: -16) }
        .overlay(alignment: .trailing) { Text("B").font(.caption2.weight(.heavy)).offset(y: -16) }
    }
}

/// Выбор трека: поиск, «Мне нравится», очередь.
struct TrackPickerSheet: View {
    var onPick: (Song) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: Player
    @State private var query = ""
    @State private var results: [Song] = []
    @State private var liked: [Song] = []

    var body: some View {
        NavigationStack {
            List {
                if !query.isEmpty {
                    Section("Поиск") { ForEach(results) { row($0) } }
                } else {
                    if !player.queue.isEmpty { Section("Очередь") { ForEach(player.queue.filter { !$0.isLocal }.prefix(15)) { row($0) } } }
                    Section("Мне нравится") { ForEach(liked) { row($0) } }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "Найти трек")
            .navigationTitle("Выбери трек")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
            .task(id: query) {
                guard !query.isEmpty else { return }
                try? await Task.sleep(for: .milliseconds(350))
                results = ((try? await API.searchTracks(query)) ?? []).map(Song.init(track:))
            }
            .task { liked = Array(((try? await API.likedSongs()) ?? []).prefix(60)) }
        }
        .presentationDetents([.large])
    }

    private func row(_ s: Song) -> some View {
        Button { onPick(s); dismiss() } label: {
            HStack(spacing: 12) {
                CoverView(url: s.coverURL(100), cornerRadius: 5).frame(width: 44, height: 44)
                VStack(alignment: .leading) {
                    Text(s.title).lineLimit(1)
                    Text(s.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
