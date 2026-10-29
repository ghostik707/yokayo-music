import SwiftUI

/// Очередь «Далее» внутри плеера.
struct QueueView: View {
    @EnvironmentObject private var player: Player

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                toggle("shuffle", on: player.shuffled) { player.toggleShuffle() }
                toggle(player.repeatMode == .one ? "repeat.1" : "repeat", on: player.repeatMode != .off) { player.cycleRepeat() }
                Spacer()
            }
            .padding(.horizontal, 28)
            HStack {
                Text(player.isWave ? "Моя волна" : "Далее").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 28)
            List {
                ForEach(Array(player.upNext.enumerated()), id: \.element.id) { i, song in
                    HStack(spacing: 12) {
                        CoverView(url: song.coverURL(100), cornerRadius: 5).frame(width: 40, height: 40)
                        VStack(alignment: .leading) {
                            Text(song.title).lineLimit(1)
                            Text(song.artist).font(.subheadline).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { player.jump(to: player.index + 1 + i) }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                .onMove { player.move(from: $0, to: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
            .frame(maxHeight: .infinity)
        }
        .padding(.top, 12)
    }

    private func toggle(_ icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.body.weight(.semibold))
                .frame(width: 64, height: 34)
                .foregroundStyle(on ? .black : .white)
                .background(on ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.white.opacity(0.14)), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
