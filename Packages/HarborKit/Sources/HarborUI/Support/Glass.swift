import SwiftUI

extension View {
    /// Liquid Glass on macOS 26+, a vibrant material elsewhere.
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.08)))
                .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        }
    }

    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self.background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
        }
    }
}
