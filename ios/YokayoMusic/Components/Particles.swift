import SwiftUI

/// Светящиеся частицы: медленно плывут вверх, мерцают, некоторые — со «звёздным» бликом.
struct ParticleField: View {
    var count = 70
    var color: Color = .neon
    var speed: Double = 1

    private struct P { let x, y, r, drift, phase, tw: Double; let star: Bool }
    private let ps: [P]

    init(count: Int = 70, color: Color = .neon, speed: Double = 1) {
        self.count = count; self.color = color; self.speed = speed
        var g = SeededRandom(seed: 7)
        ps = (0..<count).map { _ in
            P(x: g.next(), y: g.next(), r: 0.6 + g.next() * 2.2, drift: 0.004 + g.next() * 0.012,
              phase: g.next() * 6.28, tw: 0.6 + g.next() * 1.8, star: g.next() > 0.88)
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate * speed
            Canvas(opaque: false, rendersAsynchronously: true) { gc, size in
                for p in ps {
                    let y = (p.y - t * p.drift).truncatingRemainder(dividingBy: 1)
                    let yy = (y < 0 ? y + 1 : y) * (size.height + 40) - 20
                    let xx = p.x * size.width + sin(t * 0.3 + p.phase) * 18
                    let a = 0.25 + 0.75 * (0.5 + 0.5 * sin(t * p.tw + p.phase))
                    let r = p.r
                    // ореол — два полупрозрачных круга вместо градиента (дёшево)
                    gc.fill(Path(ellipseIn: CGRect(x: xx - r * 3, y: yy - r * 3, width: r * 6, height: r * 6)),
                            with: .color(color.opacity(0.10 * a)))
                    gc.fill(Path(ellipseIn: CGRect(x: xx - r * 1.6, y: yy - r * 1.6, width: r * 3.2, height: r * 3.2)),
                            with: .color(color.opacity(0.22 * a)))
                    gc.fill(Path(ellipseIn: CGRect(x: xx - r / 2, y: yy - r / 2, width: r, height: r)),
                            with: .color(.white.opacity(0.9 * a)))
                    if p.star {
                        var cross = Path()
                        cross.move(to: CGPoint(x: xx - r * 5, y: yy)); cross.addLine(to: CGPoint(x: xx + r * 5, y: yy))
                        cross.move(to: CGPoint(x: xx, y: yy - r * 5)); cross.addLine(to: CGPoint(x: xx, y: yy + r * 5))
                        gc.stroke(cross, with: .color(color.opacity(0.5 * a)), lineWidth: 0.6)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}

/// Фирменный фон Yokayo: чёрный, неоновое сияние сверху, частицы.
struct YokayoBackground: View {
    @ObservedObject private var settings = AppSettings.shared
    var body: some View {
        ZStack {
            Color.black
            RadialGradient(colors: [Color.neonDeep.opacity(0.35), .clear], center: .top, startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Color.neon.opacity(0.12), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 380)
            if settings.particles {
                NeonRays().opacity(0.35)
                ParticleField()
            }
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Фон для экранов со списками: прячем системный фон и кладём наш.
    func yokayoBackground() -> some View {
        self.scrollContentBackground(.hidden)
            .background { YokayoBackground() }
    }
}
