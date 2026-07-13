import AppKit
import SwiftUI

enum WordNoteTheme {
    static let canvas = adaptive(light: 0xF6F7F5, dark: 0x1E1E1E)
    static let sidebar = adaptive(light: 0xEFF1EE, dark: 0x171717)
    static let surface = adaptive(light: 0xFBFCFA, dark: 0x232323)
    static let raisedSurface = adaptive(light: 0xFFFFFF, dark: 0x2A2A2A)
    static let field = adaptive(light: 0xFFFFFF, dark: 0x242424)
    static let line = adaptive(light: 0xD8DCD6, dark: 0x3A3A3A)
    static let strongLine = adaptive(light: 0xBEC4BB, dark: 0x505050)
    static let mutedInk = adaptive(light: 0x66706A, dark: 0xA6A6A6)

    static let brand = adaptive(light: 0x842D37, dark: 0xD98289)
    static let teal = adaptive(light: 0x0D6472, dark: 0x69B7C2)
    static let amber = adaptive(light: 0x9A6227, dark: 0xD6A05C)
    static let green = adaptive(light: 0x376B55, dark: 0x73AF8E)

    static func editorialFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                return nsColor(hex: value)
            }
        )
    }

    private static func nsColor(hex: UInt32) -> NSColor {
        NSColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

private struct WordNoteSurfaceModifier: ViewModifier {
    let elevated: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(elevated ? WordNoteTheme.raisedSurface : WordNoteTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(WordNoteTheme.line, lineWidth: 1)
            }
    }
}

extension View {
    func wordNoteSurface(elevated: Bool = false, cornerRadius: CGFloat = 6) -> some View {
        modifier(WordNoteSurfaceModifier(elevated: elevated, cornerRadius: cornerRadius))
    }
}

struct WordNoteGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label
                .font(WordNoteTheme.editorialFont(size: 15, weight: .semibold))
            configuration.content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wordNoteSurface()
    }
}
