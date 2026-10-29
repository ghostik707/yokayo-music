import SwiftUI

/// Эквалайзер: 10 полос, пресеты и свой. Тянешь ползунок — слышно сразу.
struct EqualizerView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: Player
    @State private var gains: [Float] = Array(repeating: 0, count: 10)
    private let range: ClosedRange<Float> = -12...12

    private var preset: EQPreset { EQPreset(rawValue: settings.eqPreset) ?? .flat }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                curve
                    .frame(height: 120)
                    .padding(.horizontal, 4)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(EQPreset.allCases) { p in
                            Button {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { select(p) }
                            } label: {
                                Text(p.title).font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(p == preset ? AnyShapeStyle(LinearGradient(colors: [.neon, .neonDeep], startPoint: .leading, endPoint: .trailing))
                                                            : AnyShapeStyle(Color.white.opacity(0.08)), in: Capsule())
                                    .foregroundStyle(p == preset ? .black : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }

                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(0..<10, id: \.self) { i in
                        BandSlider(value: $gains[i], range: range) { editing in
                            if editing { becomeCustom() } else { save() }
                            player.previewEQ(gains)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 260)
                .padding(.horizontal, 10)

                HStack(spacing: 0) {
                    ForEach(EQPreset.labels, id: \.self) { Text($0).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
                }
                .padding(.horizontal, 10)

                Button {
                    withAnimation(.spring) { select(.flat) }
                } label: { Label("Сбросить", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(.bordered).tint(.white)

                Text("Полосы от 32 Гц (саб-бас) до 16 кГц (воздух). Свои настройки сохраняются в пресет «Свой». Работает для Яндекса, своих файлов и DJ-режима.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 24)
            }
            .padding(.vertical, 16)
        }
        .yokayoBackground()
        .navigationTitle("Эквалайзер")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { gains = preset.gains }
    }

    private func select(_ p: EQPreset) {
        settings.eqPreset = p.rawValue
        gains = p.gains
        player.applyEQ()
    }

    /// Первое касание ползунка в готовом пресете — превращаем его в «Свой».
    private func becomeCustom() {
        guard preset != .custom else { return }
        settings.customEQ = gains
        settings.eqPreset = EQPreset.custom.rawValue
    }

    private func save() {
        settings.customEQ = gains
        player.applyEQ()
    }

    /// Плавная кривая АЧХ по полосам.
    private var curve: some View {
        Canvas { gc, size in
            let n = gains.count
            func pt(_ i: Int) -> CGPoint {
                CGPoint(x: size.width * (CGFloat(i) + 0.5) / CGFloat(n),
                        y: size.height / 2 - CGFloat(gains[i]) / 12 * size.height / 2 * 0.9)
            }
            var mid = Path(); mid.move(to: CGPoint(x: 0, y: size.height / 2)); mid.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            gc.stroke(mid, with: .color(.white.opacity(0.15)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            var p = Path()
            p.move(to: CGPoint(x: 0, y: pt(0).y))
            p.addLine(to: pt(0))
            for i in 1..<n {
                let a = pt(i - 1), b = pt(i)
                p.addCurve(to: b, control1: CGPoint(x: (a.x + b.x) / 2, y: a.y), control2: CGPoint(x: (a.x + b.x) / 2, y: b.y))
            }
            p.addLine(to: CGPoint(x: size.width, y: pt(n - 1).y))
            var fill = p
            fill.addLine(to: CGPoint(x: size.width, y: size.height)); fill.addLine(to: CGPoint(x: 0, y: size.height)); fill.closeSubpath()
            gc.fill(fill, with: .linearGradient(Gradient(colors: [Color.neon.opacity(0.35), .clear]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            gc.stroke(p, with: .linearGradient(Gradient(colors: [.neon, .neonDeep, .purple]), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)), lineWidth: 3)
        }
    }
}

/// Вертикальный ползунок одной полосы.
private struct BandSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    var onEdit: (Bool) -> Void
    @State private var dragging = false

    var body: some View {
        VStack(spacing: 6) {
            Text(String(format: "%+.0f", value)).font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(dragging ? Color.neon : .secondary)
            GeometryReader { g in
                let h = g.size.height
                let frac = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
                ZStack(alignment: .bottom) {
                    Capsule().fill(Color.white.opacity(0.08)).frame(width: 6)
                    Capsule().fill(LinearGradient(colors: [.neonDeep, .neon], startPoint: .bottom, endPoint: .top))
                        .frame(width: 6, height: max(6, h * frac))
                    Circle().fill(.white).frame(width: dragging ? 26 : 20)
                        .shadow(color: Color.neon.opacity(0.8), radius: dragging ? 10 : 4)
                        .offset(y: -(h * frac) + 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !dragging { dragging = true; onEdit(true) }
                        let f = 1 - min(1, max(0, v.location.y / h))
                        let new = range.lowerBound + Float(f) * (range.upperBound - range.lowerBound)
                        let stepped = (new * 2).rounded() / 2
                        if stepped != value { value = stepped; UISelectionFeedbackGenerator().selectionChanged(); onEdit(true) }
                    }
                    .onEnded { _ in dragging = false; onEdit(false) })
            }
        }
        .animation(.spring(response: 0.25), value: dragging)
    }
}
