import SwiftUI

/// The small live indicator at the start of each tab.
struct SessionStatusIndicator: View {
    let status: TabStatus

    var body: some View {
        ZStack {
            switch status {
            case .busy:
                SpinnerRing(color: .blue)
            case .streaming:
                PulsingDot(color: .teal)
            case .starting:
                PulsingDot(color: .secondary)
            case .idle:
                Circle().fill(Color.green.opacity(0.85)).frame(width: 7, height: 7)
            case .idleAfterFailure:
                Circle().fill(Color.orange).frame(width: 7, height: 7)
            case .newOutput:
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                    .shadow(color: .accentColor.opacity(0.7), radius: 3)
            case .bell:
                Image(systemName: "bell.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(.orange)
            case .exited:
                Circle().strokeBorder(Color.secondary, lineWidth: 1.3).frame(width: 8, height: 8)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(.red)
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityElement()
        .accessibilityLabel(status.label)
    }
}

/// An open ring that spins while a command runs.
private struct SpinnerRing: View {
    let color: Color
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 0.82)
            .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            .frame(width: 10, height: 10)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

/// A dot that breathes while output streams.
private struct PulsingDot: View {
    let color: Color
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .scaleEffect(pulsing ? 1 : 0.55)
            .opacity(pulsing ? 1 : 0.45)
            .animation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}
