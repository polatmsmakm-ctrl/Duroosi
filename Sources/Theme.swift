import SwiftUI
import UIKit

extension Color {
    static let appBg = Color(red: 0.04, green: 0.04, blue: 0.065)
    static let cardBg = Color(red: 0.07, green: 0.07, blue: 0.11).opacity(0.74)
    static let cardBg2 = Color(red: 0.13, green: 0.13, blue: 0.20).opacity(0.88)
    static let accentBlue = Color(red: 0.91, green: 0.56, blue: 0.20)   // ذهبي كوني
    static let goldDeep = Color(red: 0.66, green: 0.32, blue: 0.10)
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

enum Nebula {
    static let image: UIImage? = UIImage(named: "nebula.jpg")
        ?? Bundle.main.path(forResource: "nebula", ofType: "jpg").flatMap { UIImage(contentsOfFile: $0) }
}

struct AppBackground: View {
    var body: some View {
        ZStack {
            Color.appBg
            if let ui = Nebula.image {
                GeometryReader { g in
                    Image(uiImage: ui).resizable().scaledToFill()
                        .frame(width: g.size.width, height: g.size.height).clipped()
                }
            }
            LinearGradient(colors: [Color.black.opacity(0.30), Color.black.opacity(0.62), Color.black.opacity(0.78)],
                           startPoint: .top, endPoint: .bottom)
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
