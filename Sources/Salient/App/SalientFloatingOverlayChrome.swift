import AppKit
import SalientCore
import SwiftUI

enum SalientFloatingOverlayDesign {
    static let cornerRadius: CGFloat = 24
    static let innerCornerRadius: CGFloat = 13
    static let shadowRadius: CGFloat = 18
    static let shadowYOffset: CGFloat = 7
}

struct SalientFloatingOverlayChrome<OverlayShape: InsettableShape>: View {
    var appearance: PlaybackHUDAppearance
    var shape: OverlayShape

    var body: some View {
        Group {
            #if compiler(>=6.2)
                if #available(macOS 26.0, *) {
                    nativeChrome
                } else {
                    fallbackChrome
                }
            #else
                fallbackChrome
            #endif
        }
    }

    #if compiler(>=6.2)
        @available(macOS 26.0, *)
        private var nativeChrome: some View {
            GlassEffectContainer(spacing: 0) {
                shape
                    .fill(nativeFillColor)
                    .glassEffect(.regular.tint(glassTint), in: shape)
                    .overlay {
                        SalientFloatingOverlayHighlights(appearance: appearance)
                            .clipShape(shape)
                    }
                    .overlay {
                        SalientFloatingOverlayStroke(appearance: appearance, shape: shape)
                    }
                    .shadow(
                        color: shadowColor, radius: SalientFloatingOverlayDesign.shadowRadius, y: SalientFloatingOverlayDesign.shadowYOffset
                    )
            }
        }
    #endif

    private var fallbackChrome: some View {
        ZStack {
            SalientFloatingOverlayMaterialBackdrop(appearance: appearance)
            shape.fill(fallbackFillColor)
            SalientFloatingOverlayHighlights(appearance: appearance)
                .clipShape(shape)
        }
        .clipShape(shape)
        .overlay {
            SalientFloatingOverlayStroke(appearance: appearance, shape: shape)
        }
        .shadow(color: shadowColor, radius: SalientFloatingOverlayDesign.shadowRadius, y: SalientFloatingOverlayDesign.shadowYOffset)
    }

    private var design: PlaybackHUDAppearanceDesign {
        PlaybackHUDAppearanceDesign(appearance: appearance)
    }

    private var glassTint: Color {
        switch appearance {
        case .dark:
            .black.opacity(design.nativeGlassTintOpacity)
        case .light:
            .white.opacity(design.nativeGlassTintOpacity)
        }
    }

    private var nativeFillColor: Color {
        switch appearance {
        case .dark:
            .black.opacity(0.05)
        case .light:
            .white.opacity(design.capsuleFillOpacity * 0.32)
        }
    }

    private var fallbackFillColor: Color {
        switch appearance {
        case .dark:
            .black.opacity(design.capsuleFillOpacity)
        case .light:
            .white.opacity(design.capsuleFillOpacity)
        }
    }

    private var shadowColor: Color {
        .black.opacity(design.fallbackShadowOpacity)
    }
}

private struct SalientFloatingOverlayHighlights: View {
    var appearance: PlaybackHUDAppearance

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    .white.opacity(appearance == .dark ? 0.22 : 0.58),
                    .white.opacity(appearance == .dark ? 0.05 : 0.18),
                    .clear,
                ],
                startPoint: .top,
                endPoint: .center
            )
            .blendMode(.screen)

            LinearGradient(
                stops: [
                    .init(
                        color: SalientTheme.teal.opacity(appearance == .dark ? 0.18 : 0.10),
                        location: 0
                    ),
                    .init(color: .clear, location: 0.42),
                    .init(
                        color: SalientTheme.coral.opacity(appearance == .dark ? 0.11 : 0.07),
                        location: 0.72
                    ),
                    .init(
                        color: SalientTheme.outlineGold.opacity(appearance == .dark ? 0.13 : 0.09),
                        location: 1
                    ),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .blendMode(.plusLighter)

            RadialGradient(
                colors: [
                    .white.opacity(appearance == .dark ? 0.14 : 0.30),
                    .clear,
                ],
                center: .topTrailing,
                startRadius: 8,
                endRadius: 180
            )
            .blendMode(.screen)

            LinearGradient(
                colors: [
                    .clear,
                    appearance == .dark ? .black.opacity(0.14) : .white.opacity(0.08),
                ],
                startPoint: .center,
                endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
    }
}

private struct SalientFloatingOverlayStroke<OverlayShape: InsettableShape>: View {
    var appearance: PlaybackHUDAppearance
    var shape: OverlayShape

    var body: some View {
        shape.strokeBorder(
            LinearGradient(
                colors: strokeColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            lineWidth: 1
        )
    }

    private var strokeColors: [Color] {
        switch appearance {
        case .dark:
            [
                .white.opacity(0.36),
                SalientTheme.teal.opacity(0.20),
                SalientTheme.outlineGold.opacity(0.14),
                .white.opacity(0.08),
            ]
        case .light:
            [
                .white.opacity(0.86),
                SalientTheme.teal.opacity(0.16),
                Color.black.opacity(0.10),
                SalientTheme.outlineGold.opacity(0.12),
            ]
        }
    }
}

private struct SalientFloatingOverlayMaterialBackdrop: NSViewRepresentable {
    var appearance: PlaybackHUDAppearance

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.appearance = NSAppearance(
            named: PlaybackHUDAppearanceDesign(appearance: appearance).panelAppearanceName
        )
        view.material = appearance == .dark ? .hudWindow : .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
    }
}
