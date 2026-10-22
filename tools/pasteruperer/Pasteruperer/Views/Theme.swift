import SwiftUI
import CoreText

/// Futuristic graffiti and paste-ups: a concrete wall, newsprint posters with ripped edges, tape,
/// spray-paint neon, and street-sign type.
enum Theme {
    static let pink = Color(red: 1, green: 0.176, blue: 0.541)      // #ff2d8a
    static let cyan = Color(red: 0.133, green: 0.953, blue: 1)      // #22f3ff
    static let acid = Color(red: 0.843, green: 1, blue: 0.227)      // #d7ff3a
    static let violet = Color(red: 0.478, green: 0.361, blue: 1)    // #7a5cff
    static let ink = Color(red: 0.082, green: 0.075, blue: 0.102)    // #15131a
    static let paper = Color(red: 0.937, green: 0.91, blue: 0.839)  // #efe8d6
    static let wall = Color(red: 0.114, green: 0.106, blue: 0.133)  // #1d1b22
    static let neons = [pink, cyan, acid, violet]

    static let inkNS = NSColor(red: 0.082, green: 0.075, blue: 0.102, alpha: 1)

    /// Street-sign capitals (Bungee).
    static func display(_ size: CGFloat) -> Font { .custom("Bungee-Regular", size: size) }
    /// Bungee with an inline highlight, for big headings.
    static func inline(_ size: CGFloat) -> Font { .custom("BungeeInline-Regular", size: size) }
    /// Marker-pen handwriting (Permanent Marker).
    static func marker(_ size: CGFloat) -> Font { .custom("PermanentMarker-Regular", size: size) }

    static func registerFonts() {
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// The same neon for the same text every time (String.hashValue changes between launches).
    static func neon(for text: String) -> Color {
        neons[Int(stableHash(text) % UInt64(neons.count))]
    }

    /// A small, stable tilt so stickers and scraps don't line up perfectly.
    static func tilt(for text: String, maximum: Double = 3) -> Angle {
        .degrees(Double(stableHash(text) % 1000) / 1000 * maximum * 2 - maximum)
    }

    static func stableHash(_ text: String) -> UInt64 {
        text.utf8.reduce(5381) { ($0 << 5) &+ $0 &+ UInt64($1) }
    }
}

// MARK: Surfaces

/// The concrete wall everything is pasted on.
struct ConcreteBackground: View {
    var body: some View {
        Image("Concrete")
            .resizable(resizingMode: .tile)
            .ignoresSafeArea()
    }
}

/// A sheet of newsprint with ripped top and bottom edges, pasted onto the wall.
struct PasteUp<Content: View>: View {
    var seed = 1
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background {
                Image("Paper")
                    .resizable(resizingMode: .tile)
                    .clipShape(TornEdges(seed: seed))
                    .shadow(color: .black.opacity(0.55), radius: 14, y: 8)
            }
            .environment(\.colorScheme, .light)
            .foregroundStyle(Theme.ink)
            .tint(Theme.pink)
    }
}

/// A rectangle whose top and bottom edges are ripped. The rip pattern depends only on position, so it
/// stays put as the sheet grows.
struct TornEdges: Shape {
    var seed: Int
    var depth: CGFloat = 7
    var step: CGFloat = 9

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + depth))
        var x = rect.minX
        var i = 0
        while x < rect.maxX {
            path.addLine(to: CGPoint(x: x, y: rect.minY + jitter(i, 0) * depth))
            x += step
            i += 1
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + depth))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - depth))
        i = 0
        while x > rect.minX {
            path.addLine(to: CGPoint(x: x, y: rect.maxY - jitter(i, 1) * depth))
            x -= step
            i += 1
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - depth))
        path.closeSubpath()
        return path
    }

    private func jitter(_ index: Int, _ edge: Int) -> CGFloat {
        var value = UInt64(truncatingIfNeeded: index &* 2_654_435_761 ^ (seed &* 40_503) ^ (edge &* 97_531))
        value ^= value >> 13
        value = value &* 0x5bd1e995
        value ^= value >> 15
        let unit = CGFloat(value % 10_000) / 10_000
        // Mostly shallow, with the odd deeper tear.
        return unit > 0.92 ? 1.8 : unit
    }
}

/// A strip of translucent tape.
struct Tape: View {
    var width: CGFloat = 86
    var angle: Angle = .degrees(-4)

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.42))
            .overlay(Rectangle().strokeBorder(Color.white.opacity(0.5), lineWidth: 0.5))
            .frame(width: width, height: 24)
            .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
            .rotationEffect(angle)
            .allowsHitTesting(false)
    }
}

/// Diagonal hazard stripes.
struct HazardStripes: View {
    var color = Theme.acid
    var width: CGFloat = 10

    var body: some View {
        Canvas { context, size in
            var x = -size.height
            while x < size.width + size.height {
                var stripe = Path()
                stripe.move(to: CGPoint(x: x, y: size.height))
                stripe.addLine(to: CGPoint(x: x + size.height, y: 0))
                stripe.addLine(to: CGPoint(x: x + size.height + width, y: 0))
                stripe.addLine(to: CGPoint(x: x + width, y: size.height))
                stripe.closeSubpath()
                context.fill(stripe, with: .color(color))
                x += width * 2
            }
        }
        .background(Theme.ink)
    }
}

// MARK: Type

extension View {
    /// Spray-paint glow.
    func neonGlow(_ color: Color, radius: CGFloat = 6) -> some View {
        shadow(color: color.opacity(0.9), radius: radius / 2)
            .shadow(color: color.opacity(0.6), radius: radius * 1.6)
    }
}

/// A small all-caps label, like stencilled signage.
struct StencilLabel: View {
    let text: String
    var color: Color = Theme.ink.opacity(0.55)
    var size: CGFloat = 11

    init(_ text: String, color: Color = Theme.ink.opacity(0.55), size: CGFloat = 11) {
        self.text = text
        self.color = color
        self.size = size
    }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.display(size))
            .foregroundStyle(color)
    }
}

// MARK: Buttons

/// A bold sticker: neon fill, ink outline and type, slightly crooked.
struct StickerButtonStyle: ButtonStyle {
    var color = Theme.acid
    var tilt: Angle = .degrees(-2)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.display(13))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(color, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.ink, lineWidth: 2))
            .rotationEffect(tilt)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .neonGlow(color, radius: configuration.isPressed ? 2 : 5)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}
