import SwiftUI

extension Color {
    static let retexCanvas = Color(red: 0.035, green: 0.043, blue: 0.051)
    static let retexSidebar = Color(red: 0.047, green: 0.055, blue: 0.064)
    static let retexSurface = Color(red: 0.066, green: 0.078, blue: 0.090)
    static let retexRaised = Color(red: 0.086, green: 0.098, blue: 0.112)
    static let retexBorder = Color.white.opacity(0.09)
    static let retexText = Color(red: 0.93, green: 0.95, blue: 0.97)
    static let retexMuted = Color(red: 0.57, green: 0.61, blue: 0.66)
    static let retexAccent = Color(red: 0.30, green: 0.73, blue: 0.94)
    static let retexSuccess = Color(red: 0.35, green: 0.78, blue: 0.56)
    static let retexWarning = Color(red: 0.93, green: 0.67, blue: 0.31)
    static let retexDanger = Color(red: 0.93, green: 0.37, blue: 0.40)
}

struct PanelModifier: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color.retexSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.retexBorder, lineWidth: 1)
            }
    }
}

extension View {
    func retexPanel(padding: CGFloat = 16) -> some View {
        modifier(PanelModifier(padding: padding))
    }

    func metadataStyle() -> some View {
        font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.retexMuted)
    }
}

struct RetexMark: View {
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                .stroke(Color.retexBorder, lineWidth: 1)
            Path { path in
                path.move(to: CGPoint(x: size * 0.27, y: size * 0.72))
                path.addLine(to: CGPoint(x: size * 0.27, y: size * 0.28))
                path.addLine(to: CGPoint(x: size * 0.55, y: size * 0.28))
                path.addCurve(
                    to: CGPoint(x: size * 0.55, y: size * 0.52),
                    control1: CGPoint(x: size * 0.76, y: size * 0.28),
                    control2: CGPoint(x: size * 0.76, y: size * 0.52)
                )
                path.addLine(to: CGPoint(x: size * 0.27, y: size * 0.52))
                path.move(to: CGPoint(x: size * 0.50, y: size * 0.52))
                path.addLine(to: CGPoint(x: size * 0.74, y: size * 0.74))
            }
            .stroke(Color.retexAccent, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct StatusDot: View {
    let status: String

    private var color: Color {
        switch status.lowercased() {
        case "won", "complete", "completed", "ready": .retexSuccess
        case "proposal", "negotiation", "queued": .retexWarning
        case "blocked", "failed": .retexDanger
        case "working", "qualified": .retexAccent
        default: .retexMuted
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .accessibilityLabel(status)
    }
}
