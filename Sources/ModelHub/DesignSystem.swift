import AppKit
import SwiftUI

enum MHDesign {
    static let pagePadding: CGFloat = 32
    static let sectionSpacing: CGFloat = 28
    static let cardRadius: CGFloat = 18
    static let compactRadius: CGFloat = 12
    static let sidebarWidth: CGFloat = 232

    static let canvas = dynamicColor(
        light: NSColor(calibratedRed: 0.958, green: 0.969, blue: 0.980, alpha: 1),
        dark: NSColor(calibratedRed: 0.055, green: 0.067, blue: 0.086, alpha: 1)
    )
    static let surface = dynamicColor(
        light: NSColor(calibratedRed: 0.976, green: 0.982, blue: 0.989, alpha: 1),
        dark: NSColor(calibratedRed: 0.082, green: 0.098, blue: 0.125, alpha: 1)
    )
    static let elevatedSurface = dynamicColor(
        light: .white,
        dark: NSColor(calibratedRed: 0.105, green: 0.125, blue: 0.158, alpha: 1)
    )
    static let insetSurface = dynamicColor(
        light: NSColor(calibratedRed: 0.933, green: 0.949, blue: 0.965, alpha: 1),
        dark: NSColor(calibratedRed: 0.067, green: 0.082, blue: 0.105, alpha: 1)
    )
    static let sidebarSurface = dynamicColor(
        light: NSColor(calibratedRed: 0.925, green: 0.945, blue: 0.965, alpha: 0.96),
        dark: NSColor(calibratedRed: 0.067, green: 0.082, blue: 0.105, alpha: 0.97)
    )
    static let border = dynamicColor(
        light: NSColor(calibratedRed: 0.831, green: 0.859, blue: 0.894, alpha: 0.78),
        dark: NSColor(calibratedRed: 0.208, green: 0.247, blue: 0.302, alpha: 0.82)
    )
    static let strongBorder = dynamicColor(
        light: NSColor(calibratedRed: 0.720, green: 0.765, blue: 0.824, alpha: 0.92),
        dark: NSColor(calibratedRed: 0.294, green: 0.345, blue: 0.416, alpha: 0.95)
    )
    static let accent = dynamicColor(
        light: NSColor(calibratedRed: 0.055, green: 0.333, blue: 0.890, alpha: 1),
        dark: NSColor(calibratedRed: 0.322, green: 0.565, blue: 1.000, alpha: 1)
    )
    static let accentSecondary = dynamicColor(
        light: NSColor(calibratedRed: 0.000, green: 0.565, blue: 0.600, alpha: 1),
        dark: NSColor(calibratedRed: 0.204, green: 0.745, blue: 0.745, alpha: 1)
    )
    static let heroStart = dynamicColor(
        light: NSColor(calibratedRed: 0.055, green: 0.105, blue: 0.220, alpha: 1),
        dark: NSColor(calibratedRed: 0.035, green: 0.063, blue: 0.133, alpha: 1)
    )
    static let heroEnd = dynamicColor(
        light: NSColor(calibratedRed: 0.040, green: 0.235, blue: 0.475, alpha: 1),
        dark: NSColor(calibratedRed: 0.035, green: 0.176, blue: 0.337, alpha: 1)
    )

    static func dynamicColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

struct MHAmbientBackground: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                MHDesign.canvas

                RadialGradient(
                    colors: [MHDesign.accent.opacity(0.095), .clear],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: max(proxy.size.width * 0.62, 520)
                )

                RadialGradient(
                    colors: [MHDesign.accentSecondary.opacity(0.050), .clear],
                    center: .bottomLeading,
                    startRadius: 0,
                    endRadius: max(proxy.size.width * 0.48, 420)
                )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

enum MHSurfaceLevel {
    case elevated
    case secondary
    case inset
}

private struct MHSurfaceModifier: ViewModifier {
    let level: MHSurfaceLevel
    let padding: CGFloat

    private var fill: Color {
        switch level {
        case .elevated: MHDesign.elevatedSurface
        case .secondary: MHDesign.surface
        case .inset: MHDesign.insetSurface
        }
    }

    private var shadowOpacity: Double {
        level == .elevated ? 0.075 : 0.025
    }

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(fill, in: RoundedRectangle(cornerRadius: MHDesign.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: MHDesign.cardRadius, style: .continuous)
                    .stroke(MHDesign.border, lineWidth: 1)
            }
            .shadow(color: .black.opacity(shadowOpacity), radius: 14, y: 6)
    }
}

extension View {
    func mhSurface(
        _ level: MHSurfaceLevel = .elevated,
        padding: CGFloat = 20
    ) -> some View {
        modifier(MHSurfaceModifier(level: level, padding: padding))
    }

    func mhPageBackground() -> some View {
        background(MHAmbientBackground())
    }
}

struct MHIconTile: View {
    let symbol: String
    var size: CGFloat = 42
    var emphasized = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(emphasized ? Color.white : MHDesign.accent)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                    .fill(
                        emphasized
                            ? AnyShapeStyle(LinearGradient(
                                colors: [MHDesign.accent, MHDesign.accentSecondary],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            : AnyShapeStyle(MHDesign.accent.opacity(0.10))
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                    .stroke(Color.white.opacity(emphasized ? 0.20 : 0), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

struct MHSectionHeading: View {
    let title: String
    var detail: String? = nil
    var trailing: AnyView? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(mhLocalized(title))
                    .font(.title3.weight(.semibold))
                if let detail {
                    Text(mhLocalized(detail))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 20)
            trailing
        }
    }
}

struct MHModalHeader: View {
    let title: String
    let subtitle: String
    let icon: String
    let trailing: AnyView

    var body: some View {
        HStack(spacing: 15) {
            MHIconTile(symbol: icon, size: 46, emphasized: true)
            VStack(alignment: .leading, spacing: 3) {
                Text(mhLocalized(title))
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                Text(mhLocalized(subtitle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 20)
            trailing
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(MHDesign.elevatedSurface.opacity(0.94))
    }
}
