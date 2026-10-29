import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var player: Player
    @State private var tab = 0
    @State private var showPlayer = false
    @Namespace private var ns

    var body: some View {
        TabView(selection: $tab) {
            Tab("Главная", systemImage: "house.fill", value: 0) { HomeView() }
            Tab("Обзор", systemImage: "square.grid.2x2.fill", value: 1) { BrowseView() }
            Tab("Медиатека", systemImage: "square.stack.fill", value: 2) { LibraryView() }
            Tab(value: 3, role: .search) { SearchView() }
        }
        .miniPlayer(show: $showPlayer, ns: ns)
        .fullScreenCover(isPresented: $showPlayer) {
            NowPlayingView()
                .navigationTransition(.zoom(sourceID: "player", in: ns))
        }
    }
}

private extension View {
    @ViewBuilder
    func miniPlayer(show: Binding<Bool>, ns: Namespace.ID) -> some View {
        if #available(iOS 26.1, *) {
            self.modifier(AccessoryMini(show: show, ns: ns))
        } else if #available(iOS 26.0, *) {
            self.tabViewBottomAccessory { AccessoryMiniPlayer(show: show).matchedTransitionSource(id: "player", in: ns) }
                .tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self.safeAreaInset(edge: .bottom) {
                MiniPlayer(show: show)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                    .padding(.horizontal, 10).padding(.bottom, 52)
                    .matchedTransitionSource(id: "player", in: ns)
            }
        }
    }
}

@available(iOS 26.1, *)
private struct AccessoryMini: ViewModifier {
    @EnvironmentObject private var player: Player
    @Binding var show: Bool
    let ns: Namespace.ID
    func body(content: Content) -> some View {
        content
            .tabViewBottomAccessory(isEnabled: player.current != nil) {
                AccessoryMiniPlayer(show: $show).matchedTransitionSource(id: "player", in: ns)
            }
            .tabBarMinimizeBehavior(.onScrollDown)
    }
}

@available(iOS 26.0, *)
private struct AccessoryMiniPlayer: View {
    @Binding var show: Bool
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    var body: some View { MiniPlayer(show: $show, inline: placement == .inline) }
}

/// Мини-плеер над таб-баром.
struct MiniPlayer: View {
    @EnvironmentObject private var player: Player
    @Binding var show: Bool
    var inline = false

    var body: some View {
        HStack(spacing: 12) {
            CoverView(url: player.current?.coverURL(100), cornerRadius: 6)
                .frame(width: 32, height: 32)
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            VStack(alignment: .leading, spacing: 0) {
                Text(player.current?.title ?? "Не исполняется").font(.subheadline.weight(.medium)).lineLimit(1)
                if let s = player.djStatus {
                    Text(s).font(.caption).foregroundStyle(Color.accentColor).lineLimit(1)
                } else if !inline, let a = player.current?.artist {
                    Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Group {
                if player.isLoading {
                    ProgressView().frame(width: 34, height: 34)
                } else {
                    Button { player.togglePlay() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                            .contentTransition(.symbolEffect(.replace)).frame(width: 34, height: 34)
                    }
                }
                if !inline {
                    Button { player.next() } label: { Image(systemName: "forward.fill").font(.title3).frame(width: 34, height: 34) }
                }
            }
            .buttonStyle(.plain)
            .disabled(player.current == nil)
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .contentShape(Rectangle())
        .onTapGesture { if player.current != nil { show = true } }
    }
}
