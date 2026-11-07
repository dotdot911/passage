import SwiftUI
#if os(iOS)
import UIKit
typealias PlatformColor = UIColor
#else
import AppKit
typealias PlatformColor = NSColor
#endif

/// The app's look: palette, typography, icon set, light or dark, and text size, on top of system layouts and components.
/// `.themed(_:)` at the root applies a theme; `ThemeStore` keeps the one the person chose.
struct Theme: Hashable, Codable {
    var palette: Palette
    var typography: Typography
    var icons: IconSet
    var appearance: Appearance = .automatic
    /// A Dynamic Type size that replaces the system's; nil follows the system.
    var textSize: TextSize?
    /// The corner radius of grouped list sections on iOS 26 and later, where the system uses 26 points.
    var cornerRadius: CGFloat = 12

    static let standard = Theme(palette: .terracotta, typography: .geist, icons: .lucide)

    init(palette: Palette, typography: Typography, icons: IconSet) {
        self.palette = palette
        self.typography = typography
        self.icons = icons
    }

    /// Settings added later fall back to their defaults, so a theme saved by an older version still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        palette = try c.decode(Palette.self, forKey: .palette)
        typography = try c.decode(Typography.self, forKey: .typography)
        icons = try c.decode(IconSet.self, forKey: .icons)
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .automatic
        textSize = try c.decodeIfPresent(TextSize.self, forKey: .textSize)
        cornerRadius = try c.decodeIfPresent(CGFloat.self, forKey: .cornerRadius) ?? 12
    }

    /// What only a rebuilt hierarchy picks up: fonts, icons and surface colors are read when views are made.
    /// Accent, appearance and text size travel through the environment and window traits instead.
    var rebuildKey: [String] {
        [palette.name, typography.sans?.prefix ?? "", typography.mono?.prefix ?? "", "\(icons)"]
    }

    /// Written only on the main thread, by `.themed(_:)`; read anywhere a font or color is built.
    nonisolated(unsafe) static var current = Theme.standard
}


/// Light, dark, or whatever the system uses.
enum Appearance: String, Hashable, Codable, CaseIterable {
    case automatic, light, dark

    var colorScheme: ColorScheme? {
        switch self {
        case .automatic: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// One of the twelve Dynamic Type sizes, from Extra Small to the largest accessibility size.
struct TextSize: Hashable, Codable {
    /// The position in `DynamicTypeSize.allCases`.
    var index: Int

    static let all = DynamicTypeSize.allCases
    static let large = TextSize(index: all.firstIndex(of: .large)!)

    var size: DynamicTypeSize { Self.all[min(max(index, 0), Self.all.count - 1)] }
}

/// Accent, the screen ground and the card behind grouped rows. Each palette is a namespaced folder in the asset
/// catalog with light, dark and high-contrast variants.
struct Palette: Hashable, Codable {
    let name: String
    /// A color the person picked in place of the palette's own accent.
    var customAccent: AccentColor?

    static let terracotta = Palette(name: "Terracotta")

    var accent: PlatformColor { customAccent?.color ?? PlatformColor(named: "\(name)/Accent")! }
    var ground: PlatformColor { PlatformColor(named: "\(name)/Ground")! }
    var card: PlatformColor { PlatformColor(named: "\(name)/Card")! }
}

/// A picked accent, stored as sRGB. Dark mode gets a lighter tint of it so it stays readable on the dark ground.
struct AccentColor: Hashable, Codable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        (self.red, self.green, self.blue) = (red, green, blue)
    }

    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    init(_ color: Color) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if os(iOS)
        UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            NSColor(color).usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        }
        #endif
        self.init(red: Double(r), green: Double(g), blue: Double(b))
    }

    var color: PlatformColor {
        // Toward white in dark mode, toward black for Increase Contrast in light mode.
        func resolve(dark: Bool, high: Bool) -> (CGFloat, CGFloat, CGFloat) {
            let mix: (Double, Double) = dark ? (1, high ? 0.45 : 0.25) : (0, high ? 0.25 : 0)
            func channel(_ v: Double) -> CGFloat { CGFloat(v + (mix.0 - v) * mix.1) }
            return (channel(red), channel(green), channel(blue))
        }
        #if os(iOS)
        return UIColor { traits in
            let (r, g, b) = resolve(dark: traits.userInterfaceStyle == .dark, high: traits.accessibilityContrast == .high)
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        }
        #else
        return NSColor(name: nil) { appearance in
            let high = appearance.bestMatch(from: [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) != nil
            let (r, g, b) = resolve(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua, high: high)
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
        #endif
    }

    var swiftUI: Color { Color(color) }
}

/// A text face and a data face. A nil family uses the system font (SF Pro or SF Mono).
struct Typography: Hashable, Codable {
    var sans: FontFamily?
    var mono: FontFamily?

    static let geist = Typography(sans: FontFamily(prefix: "Geist"), mono: FontFamily(prefix: "GeistMono"))
    static let system = Typography(sans: nil, mono: nil)
}

/// A bundled family with Regular, Medium, SemiBold and Bold faces named `<prefix>-<Weight>`.
struct FontFamily: Hashable, Codable {
    let prefix: String

    /// The face for a weight, one step heavier when Bold Text is on, as system fonts do.
    func face(_ weight: Font.Weight) -> String {
        let steps = ["Regular", "Medium", "SemiBold", "Bold"]
        var index = switch weight {
        case .bold, .heavy, .black: 3
        case .semibold: 2
        case .medium: 1
        default: 0
        }
        #if os(iOS)
        if UIAccessibility.isBoldTextEnabled { index = min(index + 1, 3) }
        #endif
        return "\(prefix)-\(steps[index])"
    }
}

/// Where `AppSymbol` icons come from.
enum IconSet: String, Hashable, Codable {
    /// Lucide outlines compiled as custom symbols in `Assets.xcassets/Icons`.
    case lucide
    case sfSymbols
}
// MARK: - Values

extension EnvironmentValues {
    /// The theme in effect, for views that must update when the accent changes without a rebuild.
    @Entry var theme = Theme.standard
}

extension Color {
    static var ground: Color { Color(Theme.current.palette.ground) }
    static var card: Color { Color(Theme.current.palette.card) }
}

extension Font {
    /// The theme's text face at a text style's size, scaling with Dynamic Type.
    static func app(_ style: TextStyle, weight: Weight? = nil) -> Font {
        let weight = weight ?? (style == .headline ? .semibold : .regular)
        guard let family = Theme.current.typography.sans else { return .system(style, weight: weight) }
        return .custom(family.face(weight), size: style.defaultSize, relativeTo: style)
    }

    /// The theme's data face, for URLs, headers, bodies and code.
    static func mono(_ style: TextStyle, weight: Weight = .regular) -> Font {
        guard let family = Theme.current.typography.mono else { return .system(style, design: .monospaced, weight: weight) }
        return .custom(family.face(weight), size: style.defaultSize, relativeTo: style)
    }
}

extension Font.TextStyle {
    /// The point size at the default Dynamic Type size on iOS, and the fixed macOS text style size on the Mac.
    var defaultSize: CGFloat {
        #if os(macOS)
        switch self {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .callout: 12
        case .subheadline: 11
        case .footnote, .caption, .caption2: 10
        default: 13
        }
        #else
        switch self {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        default: 17
        }
        #endif
    }
}

// MARK: - Store

/// The theme the person picked in Appearance, kept in user defaults.
@MainActor @Observable
final class ThemeStore {
    var theme: Theme {
        didSet { save() }
    }

    private static let key = "theme"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(Theme.self, from: data) {
            theme = saved
        } else {
            theme = .standard
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(theme) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
