import SwiftUI

/// Меню таймера сна в плеере.
struct SleepTimerMenu: View {
    @EnvironmentObject private var player: Player

    var body: some View {
        Menu {
            ForEach([15, 30, 45, 60], id: \.self) { m in
                Button("\(m) минут") { player.setSleep(minutes: m) }
            }
            Button("До конца трека") { player.setSleepEndOfTrack() }
            if player.sleepActive {
                Divider()
                Button("Выключить таймер", role: .destructive) { player.cancelSleep() }
            }
        } label: {
            Label(player.sleepLabel ?? "Таймер сна", systemImage: player.sleepActive ? "moon.zzz.fill" : "moon.zzz")
        }
    }
}
