import SwiftUI

/// Design tokens for the app. Semantic colors so light/dark both look right.
enum Theme {
    static let accent = Color(red: 0.36, green: 0.52, blue: 0.66)   // muted steel blue
    static let good = Color(red: 0.30, green: 0.60, blue: 0.42)
    static let warn = Color(red: 0.80, green: 0.55, blue: 0.20)

    static let corner: CGFloat = 12
    static let pad: CGFloat = 20
}

/// A quietly bordered panel. One radius, one hairline, no drop shadow.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(Theme.pad)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
    }
}
