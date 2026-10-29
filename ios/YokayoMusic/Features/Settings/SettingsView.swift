import SwiftUI
import UniformTypeIdentifiers


/// Настройки: профиль, быстрые плитки и стеклянные карточки по темам.
struct SettingsView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var player: Player
    @ObservedObject private var stats = ListeningStats.shared
    @Environment(\.dismiss) private var dismiss
    @State private var cacheSize: Int64 = 0
    @State private var offlineSize: Int64 = 0
    @State private var confirmLogout = false
    @State private var confirmClear = false
    @State private var showLogin = false
    @State private var importing = false
    @State private var route: Route?

    enum Route: Hashable { case dj, lab, stats, myMusic, eq }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    ProfileCard(onLogin: { showLogin = true }, onLogout: { confirmLogout = true })
                    statsStrip
                    tiles

                    SCard("Звук", symbol: "hifispeaker.2.fill", color: .mint) {
                        SNavRow(symbol: "slider.vertical.3", color: .mint, title: "Эквалайзер",
                                value: EQPreset(rawValue: settings.eqPreset)?.title ?? "") { route = .eq }
                        SToggleRow(symbol: "speaker.wave.2.fill", color: .teal, title: "Ровная громкость",
                                   subtitle: "Все треки звучат одинаково громко (−14 LUFS)", isOn: $settings.normalize)
                        SRow(symbol: "arrow.left.and.right", color: .blue, title: "Кроссфейд",
                             subtitle: settings.djEnabled ? "В DJ-режиме треки сводит ИИ" : "Плавная смена треков без DJ-режима") {
                            Text(settings.crossfade < 1 ? "Выкл." : "\(Int(settings.crossfade)) с").foregroundStyle(.secondary).monospacedDigit()
                        } below: {
                            Slider(value: $settings.crossfade, in: 0...12, step: 1).disabled(settings.djEnabled)
                        }
                    }

                    SCard("Качество", symbol: "waveform", color: .pink) {
                        SRow(symbol: "wifi", color: .blue, title: "По Wi-Fi") { EmptyView() } below: {
                            Picker("", selection: $settings.quality) {
                                Text("128").tag(128); Text("192").tag(192); Text("320 кбит/с").tag(320)
                            }.pickerStyle(.segmented)
                        }
                        SRow(symbol: "antenna.radiowaves.left.and.right", color: .green, title: "Мобильная сеть") { EmptyView() } below: {
                            Picker("", selection: $settings.qualityCellular) {
                                Text("128").tag(128); Text("192").tag(192); Text("320 кбит/с").tag(320)
                            }.pickerStyle(.segmented)
                        }
                        SFooter("Yokayo сам понимает, какая сейчас сеть. В режиме экономии данных включается мобильное качество.")
                    }

                    SCard("Экран и плеер", symbol: "iphone.gen3", color: .orange) {
                        SToggleRow(symbol: "lock.iphone", color: .teal, title: "Обложка на весь экран блокировки", isOn: $settings.lockFullScreen)
                        SToggleRow(symbol: "play.rectangle.fill", color: .orange, title: "Анимированные обложки",
                                   subtitle: "В плеере и на экране блокировки (iOS 26+)", isOn: $settings.animatedCovers)
                        SToggleRow(symbol: "sparkles", color: .cyan, title: "Частицы на фоне", isOn: $settings.particles)
                        SToggleRow(symbol: "e.square.fill", color: .red, title: "Контент 18+", isOn: $settings.showExplicit)
                    }

                    SCard("Своя музыка", symbol: "folder.fill", color: .green) {
                        SNavRow(symbol: "folder.badge.plus", color: .green, title: "Добавить из «Файлов»", value: "MP3, FLAC, M4A…") { importing = true }
                        SNavRow(symbol: "music.note", color: .purple, title: "Моя музыка", value: "\(library.mySongs.count)") { route = .myMusic }
                    }

                    SCard("Хранилище", symbol: "internaldrive.fill", color: .gray) {
                        SRow(symbol: "arrow.down.circle.fill", color: .blue, title: "Загрузки") {
                            Text(ByteCountFormatter.string(fromByteCount: offlineSize, countStyle: .file)).foregroundStyle(.secondary)
                        }
                        SRow(symbol: "internaldrive.fill", color: .gray, title: "Кэш прослушивания") {
                            Button("Очистить") { confirmClear = true }.font(.subheadline.weight(.semibold))
                                .disabled(cacheSize == 0)
                        }
                        SFooter("Кэш — \(ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file)). Загрузки хранятся только внутри Yokayo.")
                    }

                    about
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
            .yokayoBackground()
            .navigationDestination(item: $route) { r in
                switch r {
                case .dj: DJSettingsView()
                case .lab: DJLabView()
                case .stats: StatsView()
                case .myMusic: MyMusicView()
                case .eq: EqualizerView()
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .onAppear(perform: refreshSizes)
            .confirmationDialog("Выйти из аккаунта Яндекса?", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("Выйти", role: .destructive) { Player.shared.pause(); session.logout() }
            }
            .confirmationDialog("Очистить кэш прослушивания?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Очистить", role: .destructive) { AudioFiles.clearCache(); refreshSizes() }
            } message: { Text("Загрузки и своя музыка не пострадают. Треки скачаются заново при прослушивании.") }
            .sheet(isPresented: $showLogin) { LoginSheet {} }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    Task { await library.importFiles(urls); Player.shared.toast = "Музыка добавлена" }
                }
            }
        }
    }

    private var statsStrip: some View {
        let week = stats.totals(lastDays: 7).values.reduce(0, +) / 60
        return HStack(spacing: 0) {
            stat("\(Int(week))", "минут за неделю")
            Divider().frame(height: 30).overlay(Color.white.opacity(0.15))
            stat("\(stats.streak)", plural(stats.streak, "день подряд", "дня подряд", "дней подряд"))
            Divider().frame(height: 30).overlay(Color.white.opacity(0.15))
            stat("\(player.liked.count)", "в «Мне нравится»")
        }
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture { route = .stats }
    }

    private func stat(_ value: String, _ caption: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.bold()).monospacedDigit().foregroundStyle(Color.neon)
            Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
            Button { route = .dj } label: {
                QuickTile(symbol: "dial.medium.fill", title: "DJ-режим",
                          value: settings.djEnabled ? (settings.djMode == "classic" ? "Классика" : "ИИ-диджей") : "Выкл.",
                          colors: [.indigo, .neonDeep], active: settings.djEnabled)
            }
            Button { route = .lab } label: {
                QuickTile(symbol: "flask.fill", title: "DJ-лаборатория", value: "Тест перехода", colors: [.purple, .pink], active: false)
            }
            Button { route = .eq } label: {
                QuickTile(symbol: "slider.vertical.3", title: "Эквалайзер", value: EQPreset(rawValue: settings.eqPreset)?.title ?? "",
                          colors: [.mint, .teal], active: settings.eqPreset != EQPreset.flat.rawValue)
            }
            Button { route = .stats } label: {
                QuickTile(symbol: "chart.bar.fill", title: "Статистика", value: "Твоя музыка", colors: [.orange, .red], active: false)
            }
        }
        .buttonStyle(PressScale())
    }

    private var about: some View {
        VStack(spacing: 10) {
            Image("Wordmark").resizable().scaledToFit().frame(maxWidth: 220)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text("Yokayo Music \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                .font(.footnote.weight(.semibold))
            Text("Открытый неофициальный клиент. Не связан с Яндексом и Apple. Музыка воспроизводится по вашей подписке.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private func refreshSizes() {
        cacheSize = AudioFiles.cacheSize()
        offlineSize = LocalLibrary.offlineSize()
    }
}

// MARK: - Карточки настроек

/// Стеклянная карточка с заголовком.
struct SCard<Content: View>: View {
    let title: String
    let symbol: String
    let color: Color
    @ViewBuilder var content: Content
    init(_ title: String, symbol: String, color: Color, @ViewBuilder content: () -> Content) {
        self.title = title; self.symbol = symbol; self.color = color; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title.uppercased(), systemImage: symbol)
                .font(.caption.weight(.bold)).foregroundStyle(color.opacity(0.9))
                .padding(.leading, 6)
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        row
                        if i < rows.count - 1 { Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 56) }
                    }
                }
            }
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.07)))
        }
    }
}

/// Строка: иконка, заголовок, подпись, справа — что угодно, снизу — элемент на всю ширину.
struct SRow<Trailing: View, Below: View>: View {
    let symbol: String
    let color: Color
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var below: Below

    init(symbol: String, color: Color, title: String, subtitle: String? = nil,
         @ViewBuilder trailing: () -> Trailing, @ViewBuilder below: () -> Below = { EmptyView() }) {
        self.symbol = symbol; self.color = color; self.title = title; self.subtitle = subtitle
        self.trailing = trailing(); self.below = below()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(color.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                trailing
            }
            below.padding(.leading, 42)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }
}

struct SToggleRow: View {
    let symbol: String
    let color: Color
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        SRow(symbol: symbol, color: color, title: title, subtitle: subtitle) {
            Toggle("", isOn: $isOn).labelsHidden().tint(Color.neonDeep)
        }
    }
}

struct SNavRow: View {
    let symbol: String
    let color: Color
    let title: String
    var value: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            SRow(symbol: symbol, color: color, title: title) {
                HStack(spacing: 6) {
                    if let value { Text(value).foregroundStyle(.secondary).lineLimit(1) }
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SFooter: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

/// Цветная иконка слева, как в Настройках iOS.
struct SettingsIcon: View {
    let symbol: String
    let color: Color
    let title: String
    var value: String? = nil
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 29, height: 29).background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title)
            if let value { Spacer(); Text(value).foregroundStyle(.secondary) }
        }
    }
}

struct DJSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: Player

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "dial.medium.fill").font(.system(size: 54))
                        .foregroundStyle(LinearGradient(colors: [.neon, .neonDeep], startPoint: .top, endPoint: .bottom))
                        .symbolEffect(.rotate, isActive: settings.djEnabled && player.isPlaying)
                    Text("DJ-режим").font(.title2.bold())
                    Text("Yokayo сам определяет темп, сильные доли и энергию треков и сводит их в непрерывный сет. Всё считается на телефоне.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                Toggle("Включить DJ-режим", isOn: $settings.djEnabled).font(.headline)
            }

            Section {
                NavigationLink { DJLabView() } label: {
                    SettingsIcon(symbol: "flask.fill", color: .purple, title: "DJ-лаборатория")
                }
            } footer: {
                Text("Выбери два любых трека — ИИ соберёт переход, сыграет его и покажет, что делает каждая дека.")
            }

            Section {
                Picker("Режим", selection: $settings.djMode) {
                    Text("ИИ-диджей").tag("ai")
                    Text("Классика").tag("classic")
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.djMode) { _, _ in player.plan = nil }
                if settings.djMode == "classic" {
                    Text("Сведение по битам с обменом басами, фильтром и эхом — как в первой версии.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Доли и сильные доли слышит своя нейросеть BeatNet — обучена с нуля и работает прямо на телефоне, без интернета", systemImage: "brain.head.profile")
                        Label("Разбирает каждый трек: темп, сетку битов, фразы, интро, дроп, аутро, тональность", systemImage: "waveform.badge.magnifyingglass")
                        Label("Интро нового трека ложится на аутро старого, дроп — ровно на границу фразы", systemImage: "metronome.fill")
                        Label("Басы никогда не звучат вместе — меняются на дропе", systemImage: "speaker.wave.2.fill")
                        Label("Тональности конфликтуют — короткий фильтр-микс; сетка ненадёжна или темп разный — чистый уход в эхо", systemImage: "music.quarternote.3")
                        Label("Никаких случайностей: одна и та же пара всегда звучит одинаково", systemImage: "checkmark.seal.fill")
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
            } header: { Text("Как сводить") }

            Section {
                if settings.djMode == "classic" {
                Picker("Длина перехода", selection: $settings.djBeats) {
                    Text("Короткий · 4 такта").tag(16)
                    Text("Средний · 8 тактов").tag(32)
                    Text("Длинный · 16 тактов").tag(64)
                }
                }
                VStack(alignment: .leading) {
                    Text("Эффекты перехода")
                    HStack {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $settings.djFX, in: 0...1)
                        Image(systemName: "sparkles").foregroundStyle(.secondary)
                    }
                }
                Toggle("Возвращать родной темп", isOn: $settings.djTempoGlide)
                Toggle(isOn: $settings.djSmartOrder) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Умная очередь")
                        Text("ИИ ставит следующим из трёх ближайших тот трек, что лучше сводится по темпу и тональности. Тратит чуть больше трафика.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onChange(of: settings.djSmartOrder) { _, _ in player.prepared = nil; player.prepareNext() }
                Button {
                    if !settings.djEnabled { settings.djEnabled = true }
                    player.previewTransition()
                } label: { Label("Послушать переход в текущей очереди", systemImage: "play.circle") }
                .disabled(player.current == nil || player.upNext.isEmpty)
            } header: { Text("Сведение") }
        }
        .yokayoBackground()
        .navigationTitle("DJ-режим")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: settings.djEnabled) { _, on in if on { player.prepareNext() } }
    }
}


/// Карточка аккаунта: аватарка Яндекса с неоновым кольцом, имя, логин, Плюс.
struct ProfileCard: View {
    @EnvironmentObject private var session: Session
    var onLogin: () -> Void
    var onLogout: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(AngularGradient(colors: [.neon, .neonDeep, .purple, .neon], center: .center))
                    .frame(width: 104, height: 104)
                    .shadow(color: Color.neon.opacity(0.6), radius: 18)
                Group {
                    if let url = session.avatarURL {
                        CoverView(url: url, cornerRadius: 46, symbol: "person.fill")
                    } else {
                        ZStack { Color.black; Image("Star").resizable().scaledToFit().padding(16) }
                    }
                }
                .frame(width: 92, height: 92)
                .clipShape(Circle())
            }
            VStack(spacing: 4) {
                Text(session.isLoggedIn ? (session.displayName.isEmpty ? "Аккаунт Яндекса" : session.displayName) : "Вы не вошли")
                    .font(.title2.bold())
                if session.isLoggedIn, !session.login.isEmpty {
                    Text("@" + session.login).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if session.isLoggedIn {
                HStack(spacing: 10) {
                    Label(session.hasPlus ? "Плюс активен" : "Без Плюса", systemImage: session.hasPlus ? "plus.circle.fill" : "minus.circle")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(session.hasPlus
                                    ? AnyShapeStyle(LinearGradient(colors: [.orange, .pink, .purple], startPoint: .leading, endPoint: .trailing))
                                    : AnyShapeStyle(Color.white.opacity(0.1)), in: Capsule())
                    Button(role: .destructive, action: onLogout) {
                        Text("Выйти").font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Color.white.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain).foregroundStyle(.red)
                }
            } else {
                Button("Войти с Яндекс ID", action: onLogin).buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.neon.opacity(0.25)))
        )
    }
}

/// Цветная плитка быстрого доступа.
struct QuickTile: View {
    let symbol: String
    let title: String
    let value: String
    let colors: [Color]
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).font(.title2.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: (colors.first ?? .clear).opacity(active ? 0.7 : 0.3), radius: active ? 10 : 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(value).font(.caption).foregroundStyle(active ? Color.neon : .secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(active ? 0.18 : 0.06)))
    }
}
