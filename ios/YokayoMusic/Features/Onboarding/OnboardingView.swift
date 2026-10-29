import SwiftUI

/// Первый запуск: появление звезды, приветствие, вход.
struct OnboardingView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var settings: AppSettings
    @State private var stage = 0
    @State private var showLogin = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            NeonRays().opacity(stage >= 1 ? 1 : 0).ignoresSafeArea()
            ParticleField(count: 90).opacity(stage >= 1 ? 1 : 0).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                GlowingStar(size: 170, visible: stage >= 1)
                    .padding(.bottom, 34)

                Text("Yokayo Music")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [.white, Color.neon], startPoint: .top, endPoint: .bottom))
                    .shadow(color: Color.neon.opacity(0.7), radius: 14)
                    .opacity(stage >= 2 ? 1 : 0)
                    .offset(y: stage >= 2 ? 0 : 16)
                    .blur(radius: stage >= 2 ? 0 : 8)

                VStack(spacing: 10) {
                    Text("Привет! Ты попал в Yokayo")
                        .font(.title3.weight(.semibold))
                    Text("Неофициальный клиент Яндекс.Музыки с дизайном в духе Apple Music. Твоя подписка и музыка — из Яндекса, оформление и фишки — наши.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 36)
                .padding(.top, 18)
                .opacity(stage >= 3 ? 1 : 0)
                .offset(y: stage >= 3 ? 0 : 12)

                Spacer()

                VStack(spacing: 14) {
                    Button { showLogin = true } label: {
                        HStack(spacing: 10) {
                            YandexMark()
                            Text("Войти с Яндекс ID").font(.headline)
                        }
                        .frame(maxWidth: .infinity).frame(height: 56)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .foregroundStyle(.black)
                    }
                    .buttonStyle(PressScale())
                    .shadow(color: Color.neon.opacity(0.45), radius: 20)

                    Button("Пока только своя музыка") { settings.onboarded = true }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
                .opacity(stage >= 4 ? 1 : 0)
                .offset(y: stage >= 4 ? 0 : 30)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showLogin) {
            LoginSheet { settings.onboarded = true }
                .presentationDetents([.large])
                .presentationCornerRadius(28)
        }
        .task {
            // сценарий появления
            for (i, delay) in [0.3, 1.1, 0.6, 0.6].enumerated() {
                try? await Task.sleep(for: .seconds(delay))
                withAnimation(.spring(response: i == 0 ? 1.4 : 0.8, dampingFraction: 0.8)) { stage = i + 1 }
            }
        }
    }
}

/// Звезда Yokayo: плавное появление, свечение, лёгкое вращение.
struct GlowingStar: View {
    var size: CGFloat
    var visible: Bool = true
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Image("Star")
                .resizable().scaledToFit()
                .frame(width: size, height: size)
                .rotationEffect(.degrees(sin(t * 0.4) * 6))
                .scaleEffect(visible ? 1 + 0.03 * sin(t * 1.6) : 0.4)
                .shadow(color: Color.neon.opacity(0.75), radius: 30 + 10 * sin(t * 1.6))
                .shadow(color: Color.neonDeep.opacity(0.6), radius: 70)
        }
        .opacity(visible ? 1 : 0)
        .blur(radius: visible ? 0 : 24)
    }
}

/// Неоновые лучи фона, как на обложке бренда.
struct NeonRays: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas(opaque: false, rendersAsynchronously: true) { gc, size in
                for i in 0..<4 {
                    var p = Path()
                    let k = Double(i)
                    let sway = sin(t * 0.25 + k) * 30
                    p.move(to: CGPoint(x: -40, y: size.height * (0.55 + 0.12 * k)))
                    p.addQuadCurve(to: CGPoint(x: size.width + 40, y: size.height * (0.1 + 0.08 * k) + sway),
                                   control: CGPoint(x: size.width * 0.35, y: size.height * (0.35 + 0.05 * k) - sway))
                    // мягкое свечение: широкий прозрачный штрих + тонкая яркая линия
                    gc.stroke(p, with: .color(Color.neon.opacity(0.07)), lineWidth: 18 + k * 6)
                    gc.stroke(p, with: .color(Color.neon.opacity(0.12)), lineWidth: 7 + k * 2)
                    gc.stroke(p, with: .color(Color.neon.opacity(0.35 - k * 0.06)), lineWidth: 1.5 + k * 0.5)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Простой знак «Я» в красном круге (без логотипов — просто буква).
struct YandexMark: View {
    var body: some View {
        Text("Я").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
            .frame(width: 26, height: 26).background(Color.red, in: Circle())
    }
}
