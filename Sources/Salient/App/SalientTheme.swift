import AppKit
import SalientCore
import SwiftUI

private struct SalientIncreasedContrastKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var salientIncreasedContrast: Bool {
        get { self[SalientIncreasedContrastKey.self] }
        set { self[SalientIncreasedContrastKey.self] = newValue }
    }
}

enum SalientTheme {
    static let teal = Color(red: 0.05, green: 0.34, blue: 0.32)
    static let verdigris = Color(red: 0.20, green: 0.44, blue: 0.40)
    static let coral = Color(red: 0.84, green: 0.38, blue: 0.28)
    static let brass = Color(red: 0.70, green: 0.52, blue: 0.23)
    static let outlineGold = Color(red: 0.95, green: 0.68, blue: 0.20)
    static let ivory = Color(red: 0.94, green: 0.90, blue: 0.80)
    static let cardRadius: CGFloat = 8
    static let pagePadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 18
    static let cardSpacing: CGFloat = 16
    static let rowSpacing: CGFloat = 12
    static let compactRowPadding: CGFloat = 12
    static let contentMaxWidth: CGFloat = 980
    static let workspacePaneSpacing: CGFloat = 16
    static let pageTrailingInset: CGFloat = 28
    static let pageBottomInset: CGFloat = 28
}

struct SalientBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let radius = max(proxy.size.width, proxy.size.height)
            ZStack {
                baseColor
                ambientWash
                RadialGradient(
                    colors: leadingGlowColors,
                    center: UnitPoint(x: -0.08, y: -0.12),
                    startRadius: 0,
                    endRadius: radius * 0.92
                )
                RadialGradient(
                    colors: trailingGlowColors,
                    center: UnitPoint(x: 1.08, y: 0.24),
                    startRadius: 0,
                    endRadius: radius * 0.84
                )
                RadialGradient(
                    colors: lowerGlowColors,
                    center: UnitPoint(x: 0.82, y: 1.14),
                    startRadius: 0,
                    endRadius: radius * 0.72
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private var baseColor: Color {
        colorScheme == .dark
            ? Color(red: 0.075, green: 0.08, blue: 0.085)
            : Color(red: 0.965, green: 0.955, blue: 0.93)
    }

    private var ambientWash: LinearGradient {
        if colorScheme == .dark {
            LinearGradient(
                colors: [
                    Color.white.opacity(0.012),
                    Color.clear,
                    Color.black.opacity(0.025),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            LinearGradient(
                colors: [
                    Color.white.opacity(0.22),
                    Color.clear,
                    SalientTheme.ivory.opacity(0.10),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var leadingGlowColors: [Color] {
        if colorScheme == .dark {
            [
                SalientTheme.teal.opacity(0.18),
                SalientTheme.verdigris.opacity(0.055),
                Color.clear,
            ]
        } else {
            [
                SalientTheme.teal.opacity(0.075),
                SalientTheme.verdigris.opacity(0.025),
                Color.clear,
            ]
        }
    }

    private var trailingGlowColors: [Color] {
        if colorScheme == .dark {
            [
                SalientTheme.coral.opacity(0.085),
                SalientTheme.coral.opacity(0.025),
                Color.clear,
            ]
        } else {
            [
                SalientTheme.coral.opacity(0.048),
                SalientTheme.coral.opacity(0.015),
                Color.clear,
            ]
        }
    }

    private var lowerGlowColors: [Color] {
        if colorScheme == .dark {
            [
                SalientTheme.brass.opacity(0.075),
                SalientTheme.brass.opacity(0.018),
                Color.clear,
            ]
        } else {
            [
                SalientTheme.brass.opacity(0.09),
                SalientTheme.ivory.opacity(0.025),
                Color.clear,
            ]
        }
    }
}

struct GlassPanel<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @Environment(\.salientIncreasedContrast) private var fixtureIncreasedContrast

    var accent: Color
    var outline: Color?
    var padding: CGFloat
    var isElevated: Bool
    var cornerRadius: CGFloat
    var content: Content

    init(
        accent: Color = SalientTheme.teal,
        outline: Color? = nil,
        padding: CGFloat = 18,
        isElevated: Bool = true,
        cornerRadius: CGFloat = SalientTheme.cardRadius,
        @ViewBuilder content: () -> Content
    ) {
        self.accent = accent
        self.outline = outline
        self.padding = padding
        self.isElevated = isElevated
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background {
                if isElevated {
                    Rectangle().fill(.regularMaterial)
                } else {
                    Color.primary.opacity(isIncreasedContrast ? 0.075 : 0.035)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(outlineColor.opacity(borderOpacity), lineWidth: isIncreasedContrast ? 1.6 : 1)
            }
            .shadow(color: outlineColor.opacity(shadowOpacity), radius: shadowRadius, y: 7)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var outlineColor: Color {
        outline ?? accent
    }

    private var borderOpacity: Double {
        if isIncreasedContrast { return isElevated ? 0.72 : 0.58 }
        return isElevated ? 0.22 : 0.18
    }

    private var isIncreasedContrast: Bool {
        accessibilityContrast == .increased || fixtureIncreasedContrast
    }

    private var shadowOpacity: Double {
        isElevated ? 0.06 : 0
    }

    private var shadowRadius: CGFloat {
        isElevated ? 12 : 0
    }
}

struct StatusPill: View {
    var text: String
    var systemImage: String?
    var tint: Color

    init(_ text: String, systemImage: String? = nil, tint: Color = SalientTheme.teal) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
            }
            Text(text)
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12))
        .clipShape(Capsule())
        .help(text)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

struct PageHeader: View {
    var title: String
    var subtitle: String
    var accent: Color

    init(title: String, subtitle: String, accent: Color = SalientTheme.teal) {
        self.title = title
        self.subtitle = subtitle
        self.accent = accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(.largeTitle, design: .serif).weight(.semibold))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Rectangle()
                .fill(accent)
                .frame(width: 46, height: 2)
        }
        .padding(.bottom, 10)
    }
}

struct PageScaffold<Content: View>: View {
    var title: String
    var subtitle: String
    var accent: Color
    var minWidth: CGFloat
    var minHeight: CGFloat
    var content: Content

    init(
        title: String,
        subtitle: String,
        accent: Color = SalientTheme.teal,
        minWidth: CGFloat = 760,
        minHeight: CGFloat = 500,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accent = accent
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: title, subtitle: subtitle, accent: accent)
            content
            Spacer(minLength: 0)
        }
        .padding(SalientTheme.pagePadding)
        .frame(minWidth: minWidth, minHeight: minHeight, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SalientBackground().ignoresSafeArea())
    }
}

struct SalientPageScrollView<Content: View>: View {
    var maxContentWidth: CGFloat
    var trailingInset: CGFloat
    var bottomInset: CGFloat
    var content: Content

    init(
        maxContentWidth: CGFloat = SalientTheme.contentMaxWidth,
        trailingInset: CGFloat = SalientTheme.pageTrailingInset,
        bottomInset: CGFloat = SalientTheme.pageBottomInset,
        @ViewBuilder content: () -> Content
    ) {
        self.maxContentWidth = maxContentWidth
        self.trailingInset = trailingInset
        self.bottomInset = bottomInset
        self.content = content()
    }

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: maxContentWidth, alignment: .leading)
                .padding(.trailing, trailingInset)
                .padding(.bottom, bottomInset)
        }
        .salientScrollTopFade(height: 16)
    }
}

extension View {
    /// Fade moving content into the canvas beneath the transparent title bar.
    /// This remains macOS 14 compatible and adds no scroll-position observation.
    func salientScrollTopFade(height: CGFloat = 28) -> some View {
        mask {
            VStack(spacing: 0) {
                LinearGradient(
                    stops: [.init(color: .clear, location: 0), .init(color: .black, location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: height)
                Color.black
            }
            .allowsHitTesting(false)
        }
    }
}

struct SettingsSection<Content: View>: View {
    var title: String
    var subtitle: String
    var accent: Color
    var content: Content

    init(
        title: String,
        subtitle: String,
        accent: Color = SalientTheme.teal,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)

            VStack(spacing: SalientTheme.cardSpacing) {
                content
            }
        }
    }
}

private struct SalientFlatRowModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @Environment(\.salientIncreasedContrast) private var fixtureIncreasedContrast

    var accent: Color
    var outline: Color?
    var fillsWidth: Bool
    var horizontalPadding: CGFloat
    var verticalPadding: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(rowBackground)
            .clipShape(shape)
            .overlay {
                shape
                    .stroke(
                        outlineColor.opacity(isIncreasedContrast ? 0.58 : 0.24),
                        lineWidth: isIncreasedContrast ? 1.6 : 1
                    )
            }
            .contentShape(shape)
    }

    private var outlineColor: Color {
        outline ?? accent
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: SalientTheme.cardRadius, style: .continuous)
    }

    private var rowBackground: some View {
        ZStack {
            Color.primary.opacity(isIncreasedContrast ? 0.075 : 0.035)
            accent.opacity(isIncreasedContrast ? 0.04 : 0.014)
        }
    }

    private var isIncreasedContrast: Bool {
        accessibilityContrast == .increased || fixtureIncreasedContrast
    }
}

extension View {
    func salientFlatRow(
        accent: Color = SalientTheme.teal,
        outline: Color? = nil,
        fillsWidth: Bool = false,
        horizontalPadding: CGFloat = 12,
        verticalPadding: CGFloat = 10
    ) -> some View {
        modifier(
            SalientFlatRowModifier(
                accent: accent,
                outline: outline,
                fillsWidth: fillsWidth,
                horizontalPadding: horizontalPadding,
                verticalPadding: verticalPadding
            ))
    }
}
