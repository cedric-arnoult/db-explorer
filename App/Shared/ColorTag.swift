import SwiftUI

/// Color used to tag a connection (e.g. red for production).
enum ColorTag: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, purple, gray

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .gray: .gray
        }
    }

    static func color(for raw: String?) -> Color? {
        raw.flatMap(ColorTag.init(rawValue:))?.color
    }
}

struct ColorDot: View {
    var tag: String?
    var body: some View {
        Circle()
            .fill(ColorTag.color(for: tag) ?? Color.secondary.opacity(0.3))
            .frame(width: 10, height: 10)
    }
}
