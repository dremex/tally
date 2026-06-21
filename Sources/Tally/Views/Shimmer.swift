import SwiftUI

/// A diagonal highlight that sweeps across a view, masked to its shape — the classic skeleton-load
/// effect. Applied to placeholder blocks shown while a tab's data is being read off the main thread.
struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1
    @State private var pulse = false

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    let w = geo.size.width
                    LinearGradient(
                        colors: [.clear, Theme.fg.opacity(0.28), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: w * 0.45)
                    .offset(x: phase * w * 1.6)
                }
            )
            .mask(content)
            // A faint breathing opacity so even the gaps between sweeps read as "active", not blank.
            .opacity(pulse ? 1.0 : 0.6)
            .onAppear {
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    phase = 1
                }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

extension View {
    func shimmer() -> some View {
        modifier(Shimmer())
    }
}

/// A single rounded placeholder bar in `Theme.bg2` — the building block of every skeleton layout.
/// Centralizes the fill colour and rounding so all skeletons stay visually consistent. Wrap a group
/// of these in `.shimmer()` to animate them together.
struct SkeletonBar: View {
    var width: CGFloat?
    var height: CGFloat
    var cornerRadius: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Theme.bg2)
            .frame(width: width, height: height)
    }
}
