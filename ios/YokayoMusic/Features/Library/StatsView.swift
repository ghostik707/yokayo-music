import SwiftUI
import Charts

/// «Твоя музыка в цифрах».
struct StatsView: View {
    @ObservedObject private var stats = ListeningStats.shared
    @State private var period = 7

    var body: some View {
        let totals = stats.totals(lastDays: period == 0 ? nil : period)
        let minutes = Int(totals.values.reduce(0, +) / 60)
        let topTracks = totals.sorted { $0.value > $1.value }.prefix(5)
        var byArtist: [String: Double] = [:]
        for (id, s) in totals { byArtist[stats.meta[id]?.artist ?? "—", default: 0] += s }
        let topArtists = byArtist.sorted { $0.value > $1.value }.prefix(5)

        return ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Picker("", selection: $period) {
                    Text("Неделя").tag(7); Text("Месяц").tag(30); Text("Всё время").tag(0)
                }
                .pickerStyle(.segmented)

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(minutes)").font(.system(size: 76, weight: .heavy)).foregroundStyle(Color.neon)
                        .shadow(color: Color.neon.opacity(0.5), radius: 16)
                        .contentTransition(.numericText())
                    Text(plural(minutes, "минута", "минуты", "минут") + " музыки").font(.title3.weight(.semibold))
                }
                if stats.streak > 1 {
                    Label("Слушаешь \(stats.streak) \(plural(stats.streak, "день", "дня", "дней")) подряд", systemImage: "flame.fill")
                        .font(.headline).foregroundStyle(.orange)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("По дням").font(.title3.bold())
                    Chart(stats.minutesPerDay(period == 7 ? 7 : 14), id: \.date) { d in
                        BarMark(x: .value("День", d.date, unit: .day), y: .value("Минуты", d.minutes))
                            .foregroundStyle(LinearGradient(colors: [.neon, .neonDeep], startPoint: .top, endPoint: .bottom))
                            .cornerRadius(5)
                    }
                    .frame(height: 160)
                    .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
                }

                if !topArtists.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Топ артистов").font(.title3.bold())
                        ForEach(Array(topArtists.enumerated()), id: \.offset) { i, a in
                            HStack {
                                Text("\(i + 1)").font(.headline.monospacedDigit()).foregroundStyle(Color.neon).frame(width: 26)
                                Text(a.key).lineLimit(1)
                                Spacer()
                                Text("\(Int(a.value / 60)) мин").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }

                if !topTracks.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Топ треков").font(.title3.bold())
                        ForEach(Array(topTracks.enumerated()), id: \.offset) { i, t in
                            let m = stats.meta[t.key]
                            HStack(spacing: 12) {
                                CoverView(url: m?.cover.flatMap(URL.init(string:)), cornerRadius: 6).frame(width: 46, height: 46)
                                VStack(alignment: .leading) {
                                    Text(m?.title ?? "—").lineLimit(1)
                                    Text(m?.artist ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text("\(Int(t.value / 60)) мин").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }

                if totals.isEmpty {
                    ContentUnavailableView("Пока пусто", systemImage: "chart.bar", description: Text("Слушай музыку — здесь появятся минуты, любимые артисты и треки."))
                }
            }
            .padding(20)
        }
        .yokayoBackground()
        .navigationTitle("Статистика")
    }
}
