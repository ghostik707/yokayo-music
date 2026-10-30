import SwiftUI

/// «Как думает ИИ»: три слоя нейронов — что услышал, по чему оценивает, какой приём выбрал.
/// Цифры настоящие: из анализа треков и оценки сотен вариантов перехода.
struct NeuralThinkingCard: View {
    @ObservedObject private var thinking = DJThinking.shared
    @AppStorage("dj.brainCollapsed") private var collapsed = false
    @State private var startedAt = Date()

    private var thought: MixComposer.Thought { thinking.thought ?? .demo }
    private var isDemo: Bool { thinking.thought == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !collapsed {
                NeuralCanvas(thought: thought, startedAt: startedAt)
                    .frame(height: thought.outputs.count > 9 ? 400 : 330)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                legend.transition(.opacity)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Color.neonDeep.opacity(0.18), Color.black.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(
            LinearGradient(colors: [.neon.opacity(0.6), .purple.opacity(0.35), .neon.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
        .onChange(of: thinking.thought) { _, _ in startedAt = Date() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(RadialGradient(colors: [.neon.opacity(0.55), .clear], center: .center, startRadius: 2, endRadius: 22))
                Image(systemName: "brain").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Как думает ИИ").font(.headline)
                Text(isDemo ? "Сыграй переход — увидишь, как ИИ выбирает" : thought.summary.isEmpty ? "Перебрал \(MixComposer.candidates) вариантов → \(thought.headline)" : thought.summary)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { collapsed.toggle() }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 14, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? 180 : 0))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.12), in: Circle())
                    .overlay(Circle().strokeBorder(Color.neon.opacity(0.4)))
            }
            .buttonStyle(PressScale())
            .accessibilityLabel(collapsed ? "Показать" : "Скрыть")
        }
    }

    private var legend: some View {
        HStack(spacing: 0) {
            Text("Услышал").frame(maxWidth: .infinity, alignment: .leading)
            Text(thought.middleTitle).frame(maxWidth: .infinity)
            Text(thought.outputTitle).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
    }
}

/// Сама сеть: нейроны, связи, бегущие импульсы, «процесс размышления» после нового решения.
private struct NeuralCanvas: View {
    let thought: MixComposer.Thought
    let startedAt: Date

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 40)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let p = min(1.6, ctx.date.timeIntervalSince(startedAt) / 2.2)   // 0…1 — думает, дальше — решено
            Canvas { gc, size in draw(&gc, size, t: t, p: p) }
        }
    }

    private func ease(_ x: Double) -> Double { let c = max(0, min(1, x)); return c * c * (3 - 2 * c) }

    private func draw(_ gc: inout GraphicsContext, _ size: CGSize, t: Double, p: Double) {
        let ins = thought.inputs, mids = thought.criteria, outs = thought.outputs
        let x0 = size.width * 0.30, x1 = size.width * 0.50, x2 = size.width * 0.66
        func ys(_ n: Int) -> [CGFloat] {
            let top: CGFloat = 12, h = size.height - 24
            return (0..<n).map { top + h * (CGFloat($0) + 0.5) / CGFloat(n) }
        }
        let y0 = ys(ins.count), y1 = ys(mids.count), y2 = ys(outs.count)
        // волна размышления: слои загораются по очереди
        let l0 = ease(p / 0.3), l1 = ease((p - 0.3) / 0.3), l2 = ease((p - 0.6) / 0.4), done = ease((p - 1) / 0.25)

        // связи вход → критерии
        for (i, a) in ins.enumerated() {
            for (j, b) in mids.enumerated() {
                let w = a.1 * b.1
                var path = Path()
                path.move(to: CGPoint(x: x0, y: y0[i]))
                path.addCurve(to: CGPoint(x: x1, y: y1[j]), control1: CGPoint(x: (x0 + x1) / 2, y: y0[i]), control2: CGPoint(x: (x0 + x1) / 2, y: y1[j]))
                gc.stroke(path, with: .color(Color.neon.opacity((0.04 + 0.22 * w) * l0)), lineWidth: 0.6 + 1.4 * w)
            }
        }
        // связи критерии → приёмы; к выбранному — ярче
        for (j, b) in mids.enumerated() {
            for (k, o) in outs.enumerated() {
                let chosen = k == thought.chosen
                let w = b.1 * o.1
                var path = Path()
                path.move(to: CGPoint(x: x1, y: y1[j]))
                path.addCurve(to: CGPoint(x: x2, y: y2[k]), control1: CGPoint(x: (x1 + x2) / 2, y: y1[j]), control2: CGPoint(x: (x1 + x2) / 2, y: y2[k]))
                let color: Color = chosen ? .neon : .purple
                gc.stroke(path, with: .color(color.opacity(((chosen ? 0.12 + 0.45 * done : 0.03) + 0.15 * w) * l1)), lineWidth: chosen ? 1 + 1.6 * done : 0.6 + w)
            }
        }

        // импульсы: бегут по связям, быстрее во время размышления
        let speed = p < 1 ? 1.6 : 0.55
        for s in 0..<26 {
            let seed = Double(s) * 12.9898
            let i = Int(abs(sin(seed) * 1000)) % ins.count
            let j = Int(abs(sin(seed * 1.7) * 1000)) % mids.count
            let k = s % 3 == 0 ? thought.chosen : Int(abs(sin(seed * 2.3) * 1000)) % outs.count
            let ph = (t * speed * (0.35 + 0.1 * Double(s % 5)) + Double(s) / 26).truncatingRemainder(dividingBy: 1)
            let pt: CGPoint
            let first = ph < 0.5
            let u = first ? ph * 2 : (ph - 0.5) * 2
            if first {
                pt = bezier(CGPoint(x: x0, y: y0[i]), CGPoint(x: x1, y: y1[j]), u)
            } else {
                pt = bezier(CGPoint(x: x1, y: y1[j]), CGPoint(x: x2, y: y2[k]), u)
            }
            let strength = first ? ins[i].1 * l0 : mids[j].1 * l1
            let hot = !first && k == thought.chosen
            let r = 1.6 + 1.6 * strength
            gc.fill(Path(ellipseIn: CGRect(x: pt.x - r * 3, y: pt.y - r * 3, width: r * 6, height: r * 6)), with: .color((hot ? Color.neon : .white).opacity(0.12 * strength)))
            gc.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)), with: .color((hot ? Color.neon : .white).opacity(0.85 * strength)))
        }

        // нейроны
        func neuron(_ c: CGPoint, _ a: Double, _ color: Color, _ big: Bool = false) {
            let breathe = 1 + 0.08 * sin(t * 2.4 + Double(c.y) * 0.05)
            let r = (big ? 7.5 : 5.0) * breathe
            gc.fill(Path(ellipseIn: CGRect(x: c.x - r * 2.6, y: c.y - r * 2.6, width: r * 5.2, height: r * 5.2)), with: .color(color.opacity(0.18 * a)))
            gc.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(Color(white: 0.08)))
            gc.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(color.opacity(0.25 + 0.75 * a)))
            gc.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(.white.opacity(0.35 * a + 0.1)), lineWidth: 0.8)
        }
        for (i, a) in ins.enumerated() {
            neuron(CGPoint(x: x0, y: y0[i]), a.1 * l0, .neon)
            gc.draw(Text(a.0).font(.system(size: 10, weight: .medium)).foregroundColor(.white.opacity(0.4 + 0.5 * l0)),
                    at: CGPoint(x: x0 - 12, y: y0[i]), anchor: .trailing)
        }
        for (j, b) in mids.enumerated() {
            neuron(CGPoint(x: x1, y: y1[j]), b.1 * l1, Color(red: 0.75, green: 0.55, blue: 1))
        }
        // подписи критериев — рядом, мелко, над нейроном
        for (j, b) in mids.enumerated() {
            gc.draw(Text(b.0).font(.system(size: 8, weight: .semibold)).foregroundColor(.white.opacity(0.25 + 0.45 * l1)),
                    at: CGPoint(x: x1, y: y1[j] - 12), anchor: .bottom)
        }
        let barX = x2 + 20, barW = size.width - barX - 2
        for (k, o) in outs.enumerated() {
            let chosen = k == thought.chosen
            let grown = o.1 * l2
            neuron(CGPoint(x: x2, y: y2[k]), chosen ? max(grown, done) : grown * 0.8, chosen ? .neon : .purple, chosen && done > 0.5)
            if chosen && done > 0 {
                let ring = 12 + 6 * sin(t * 3)
                gc.stroke(Path(ellipseIn: CGRect(x: x2 - ring, y: y2[k] - ring, width: ring * 2, height: ring * 2)), with: .color(Color.neon.opacity(0.7 * done)), lineWidth: 1.4)
            }
            // полоса оценки
            let bar = CGRect(x: barX, y: y2[k] + 3, width: barW * grown, height: 3)
            gc.fill(Path(roundedRect: CGRect(x: barX, y: y2[k] + 3, width: barW, height: 3), cornerRadius: 1.5), with: .color(.white.opacity(0.07)))
            gc.fill(Path(roundedRect: bar, cornerRadius: 1.5), with: chosen
                    ? .linearGradient(Gradient(colors: [.neon, .neonDeep]), startPoint: bar.origin, endPoint: CGPoint(x: bar.maxX, y: bar.minY))
                    : .color(.purple.opacity(0.55)))
            gc.draw(Text(o.0).font(.system(size: 10, weight: chosen ? .bold : .medium))
                        .foregroundColor(chosen ? Color.neon.opacity(0.6 + 0.4 * done) : .white.opacity(0.35 + 0.4 * l2)),
                    at: CGPoint(x: barX, y: y2[k] - 1), anchor: .bottomLeading)
        }

        // счётчик перебора
        if p < 1.1 {
            let n = Int(Double(MixComposer.candidates) * min(1, p))
            gc.draw(Text("перебираю \(n) / \(MixComposer.candidates)").font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundColor(Color.neon.opacity(0.8 * (1 - ease((p - 1) / 0.1)))),
                    at: CGPoint(x: x1, y: size.height - 2), anchor: .bottom)
        }
    }

    private func bezier(_ a: CGPoint, _ b: CGPoint, _ u: Double) -> CGPoint {
        let mx = (a.x + b.x) / 2
        let c1 = CGPoint(x: mx, y: a.y), c2 = CGPoint(x: mx, y: b.y)
        let v = 1 - u
        let x = v * v * v * a.x + 3 * v * v * u * c1.x + 3 * v * u * u * c2.x + u * u * u * b.x
        let y = v * v * v * a.y + 3 * v * v * u * c1.y + 3 * v * u * u * c2.y + u * u * u * b.y
        return CGPoint(x: x, y: y)
    }
}

extension MixComposer.Thought {
    /// Пример, пока ИИ ещё не сводил: чтобы сеть было видно сразу.
    static let demo = MixComposer.Thought(
        inputs: [("Темп", 0.9), ("Сетка битов", 0.8), ("Тональность", 0.85), ("Энергия A", 0.6), ("Энергия B", 0.4), ("Дроп B", 0.7), ("Интро B", 0.5)],
        criteria: [("Басы не спорят", 0.9), ("Ровная громкость", 0.8), ("Без перегруза", 0.95), ("Голоса не мешают", 0.7), ("Стиль трека", 0.75), ("Новизна", 0.85), ("Твой вкус", 0.5)],
        outputs: zip(MixComposer.exitNames, [0.62, 0.55, 0.9, 0.7, 0.35, 0.4, 0.5, 0.3, 0.6]).map { ($0, $1) },
        chosen: 2, headline: "Эхо · на сильную долю")
}
