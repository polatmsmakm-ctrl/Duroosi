import SwiftUI
import UIKit

extension Color {
    static let appBg = Color(red: 0.04, green: 0.04, blue: 0.065)
    static let cardBg = Color(red: 0.095, green: 0.095, blue: 0.135)
    static let cardBg2 = Color(red: 0.14, green: 0.14, blue: 0.20)
    static let accentBlue = Color(red: 0.49, green: 0.40, blue: 1.0)
    static let doneGreen = Color(red: 0.25, green: 0.80, blue: 0.48)
    static let dim = Color.white.opacity(0.62)
}

struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

struct StarField: View {
    var body: some View {
        Canvas { ctx, size in
            var g = SeededRNG(seed: 11)
            for _ in 0..<110 {
                let x = Double.random(in: 0..<max(size.width, 1), using: &g)
                let y = Double.random(in: 0..<max(size.height, 1), using: &g)
                let r = Double.random(in: 0.6..<2.0, using: &g)
                let o = Double.random(in: 0.15..<0.75, using: &g)
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)), with: .color(.white.opacity(o)))
            }
        }
        .allowsHitTesting(false)
    }
}

struct AppBackground: View {
    var body: some View {
        ZStack {
            Color.appBg
            GeometryReader { g in
                Circle().fill(Color(red: 0.45, green: 0.30, blue: 1.0).opacity(0.28))
                    .frame(width: g.size.width * 0.9).blur(radius: 90)
                    .offset(x: -g.size.width * 0.35, y: -g.size.width * 0.35)
                Circle().fill(Color(red: 0.10, green: 0.60, blue: 0.85).opacity(0.18))
                    .frame(width: g.size.width * 0.8).blur(radius: 90)
                    .offset(x: g.size.width * 0.5, y: g.size.height * 0.55)
            }
        }
        .ignoresSafeArea()
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat
    var corners: UIRectCorner
    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect, byRoundingCorners: corners,
                          cornerRadii: CGSize(width: radius, height: radius)).cgPath)
    }
}

struct ProgressRing: View {
    var progress: Double
    var size: CGFloat = 26
    var body: some View {
        ZStack {
            if progress >= 0.95 {
                Circle().fill(Color.cardBg2)
                Circle().stroke(Color.accentBlue, lineWidth: 3)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.42, weight: .heavy))
                    .foregroundColor(.white)
            } else {
                Circle().fill(Color.cardBg)
                Circle().stroke(Color.accentBlue.opacity(0.3), lineWidth: 3)
                Circle().trim(from: 0, to: CGFloat(max(progress, 0.04)))
                    .stroke(Color.accentBlue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: size, height: size)
    }
}

struct SubjectOrb: View {
    let subject: Subject
    var size: CGFloat = 64
    var body: some View {
        ZStack {
            Circle().fill(Palette.glow(subject.colorIndex).opacity(0.35)).blur(radius: size * 0.25)
            Circle().fill(Palette.gradient(subject.colorIndex))
            Image(systemName: subject.icon)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }
}

func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
    UIImpactFeedbackGenerator(style: style).impactOccurred()
}
