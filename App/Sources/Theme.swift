import ObjectiveC
import SwiftUI
import UIKit

extension Theme {
    /// Sets the UIKit bars SwiftUI does not style itself.
    @MainActor func install() {
        Theme.current = self
        applyWindowTraits()
        ListCorners.install()
        ListCorners.refresh()
        let barItem = [NSAttributedString.Key.font: UIFont.app(.body)]
        let nav = UINavigationBar.appearance()
        let title = UIFont.app(.headline, weight: .semibold), largeTitle = UIFont.app(.largeTitle, weight: .bold)
        nav.titleTextAttributes = [.font: title]
        nav.largeTitleTextAttributes = [.font: largeTitle]
        if #available(iOS 26, *) {
            // Subtitles are styled only through an appearance object. A transparent one matches iOS 26's own bars,
            // which have no background and leave the blur to the scroll edge effect.
            let bar = UINavigationBarAppearance()
            bar.configureWithTransparentBackground()
            bar.titleTextAttributes = [.font: title]
            bar.largeTitleTextAttributes = [.font: largeTitle]
            bar.subtitleTextAttributes = [.font: UIFont.app(.caption, weight: .regular)]
            bar.largeSubtitleTextAttributes = [.font: UIFont.app(.subheadline)]
            for button in [bar.buttonAppearance, bar.doneButtonAppearance, bar.backButtonAppearance] {
                button.normal.titleTextAttributes = barItem
                button.highlighted.titleTextAttributes = barItem
            }
            nav.standardAppearance = bar
            nav.compactAppearance = bar
            nav.scrollEdgeAppearance = bar
        }
        UIBarButtonItem.appearance().setTitleTextAttributes(barItem, for: .normal)
        UIBarButtonItem.appearance().setTitleTextAttributes(barItem, for: .highlighted)
        UITabBarItem.appearance().setTitleTextAttributes([.font: UIFont.app(.caption2, weight: .medium)], for: .normal)
        UISegmentedControl.appearance().setTitleTextAttributes([.font: UIFont.app(.footnote, weight: .medium)], for: .normal)
        UISearchTextField.appearance().font = .app(.body)
    }

    /// Light or dark and the text size also reach UIKit: alerts, text views and controllers presented outside SwiftUI.
    @MainActor private func applyWindowTraits() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            // Shows through the status bar and any container SwiftUI leaves clear. Only the app's own windows: the
            // keyboard's text effects window sits above them and must stay clear, or it hides the whole screen.
            for window in scene.windows where window.windowLevel == .normal { window.backgroundColor = palette.ground }
            if let style = appearance.style {
                scene.traitOverrides.userInterfaceStyle = style
            } else {
                scene.traitOverrides.remove(UITraitUserInterfaceStyle.self)
            }
            if let textSize {
                scene.traitOverrides.preferredContentSizeCategory = textSize.category
            } else {
                scene.traitOverrides.remove(UITraitPreferredContentSizeCategory.self)
            }
        }
    }
}

extension Appearance {
    var style: UIUserInterfaceStyle? {
        switch self {
        case .automatic: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

extension TextSize {
    var category: UIContentSizeCategory {
        switch size {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}

// MARK: - Applying

extension View {
    /// Applies `theme` to everything below: accent, default font, light or dark, text size and the UIKit bars.
    func themed(_ theme: Theme) -> some View {
        modifier(ThemeRoot(theme: theme))
    }

    /// A row in a selectable list. A custom row background hides the system selection, so the row draws it.
    /// Selection is a light accent wash with ordinary text.
    func themedRow(selected: Bool, plain: Bool = false) -> some View {
        // Fixed colors, since the hierarchical styles turn white on a selected row.
        foregroundStyle(Color(uiColor: .label), Color(uiColor: .secondaryLabel))
            .listRowBackground(ZStack {
                plain ? Color.clear : Color.card
                if selected { Rectangle().fill(.tint).opacity(0.18) }
            })
    }

    /// The theme's default font and tint, for a view hosted outside the themed root (a UIKit-presented controller).
    func themedContent(_ theme: Theme = Theme.current) -> some View {
        font(.app(.body))
            .tint(Color(uiColor: theme.palette.accent))
            .environment(\.theme, theme)
    }

    /// The theme's ground for a navigation container that would otherwise be opaque system white, such as a column with an inspector.
    @ViewBuilder func groundContainer() -> some View {
        if #available(iOS 18, *) {
            containerBackground(Color.ground, for: .navigation)
        } else {
            self
        }
    }

    /// The theme's ground behind a screen that is not a list, edge to edge.
    func themedBackground() -> some View {
        background(Color.ground.ignoresSafeArea())
    }
}

private struct ThemeRoot: ViewModifier {
    let theme: Theme

    init(theme: Theme) {
        self.theme = theme
        MainActor.assumeIsolated { theme.install() }
    }

    func body(content: Content) -> some View {
        content
            .themedContent(theme)
            .preferredColorScheme(theme.appearance.colorScheme)
            .transformEnvironment(\.dynamicTypeSize) { size in
                if let custom = theme.textSize { size = custom.size }
            }
            .id(theme.rebuildKey)
            // The window scene may connect after the first install.
            .onAppear { theme.install() }
    }
}

/// A `List` on the theme's ground; unless `plain`, its rows sit on cards.
struct AppList<SelectionValue: Hashable, Content: View>: View {
    private let list: List<SelectionValue, ThemedRows<Content>>
    private let plain: Bool

    var body: some View {
        if plain {
            list.listStyle(.plain).scrollContentBackground(.hidden).background(Color.ground)
        } else {
            list.listStyle(.insetGrouped).scrollContentBackground(.hidden).background(Color.ground)
        }
    }
}

extension AppList where SelectionValue == Never {
    init(plain: Bool = false, @ViewBuilder content: () -> Content) {
        list = List { ThemedRows(plain: plain, content: content()) }
        self.plain = plain
    }
}

extension AppList where SelectionValue == Never {
    init<Data: RandomAccessCollection, ID: Hashable, Row: View>(
        plain: Bool = false, _ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder rowContent: @escaping (Data.Element) -> Row
    ) where Content == ForEach<Data, ID, Row> {
        self.init(plain: plain) { ForEach(data, id: id, content: rowContent) }
    }

    init<Data: RandomAccessCollection, Row: View>(
        plain: Bool = false, _ data: Data, @ViewBuilder rowContent: @escaping (Data.Element) -> Row
    ) where Data.Element: Identifiable, Content == ForEach<Data, Data.Element.ID, Row> {
        self.init(plain: plain) { ForEach(data, content: rowContent) }
    }
}

extension AppList {
    init(plain: Bool = false, selection: Binding<Set<SelectionValue>>?, @ViewBuilder content: () -> Content) {
        list = List(selection: selection) { ThemedRows(plain: plain, content: content()) }
        self.plain = plain
    }

    init(plain: Bool = false, selection: Binding<SelectionValue?>?, @ViewBuilder content: () -> Content) {
        list = List(selection: selection) { ThemedRows(plain: plain, content: content()) }
        self.plain = plain
    }
}

/// A `Form` on the theme's ground with its rows on cards.
struct AppForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { ThemedRows(plain: false, content: content) }
            .scrollContentBackground(.hidden)
            .background(Color.ground)
    }
}

/// Puts each row of a grouped list on the theme's card, and leaves plain rows on the ground.
/// The modifier has to sit on the rows, not the list.
struct ThemedRows<Content: View>: View {
    let plain: Bool
    let content: Content

    var body: some View {
        content.listRowBackground(plain ? Color.clear : Color.card)
    }
}

/// A section footer in the theme's footnote size, since the body font set at the root reaches footers too.
struct SectionFooter<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View { content.font(.app(.footnote)) }
}

// MARK: - Empty columns

/// What an empty split view column shows: one line of grey text, like Mail's "No Message Selected".
struct EmptyColumn<Actions: View>: View {
    let title: LocalizedStringKey
    let actions: Actions

    init(_ title: LocalizedStringKey, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.app(.title3, weight: .medium))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            actions
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedBackground()
    }
}

/// A sidebar row: an icon tile, the name and a current value, like the Settings app's sidebar.
struct SidebarRow: View {
    let title: LocalizedStringKey
    let symbol: AppSymbol
    var value: String?

    init(_ title: LocalizedStringKey, symbol: AppSymbol, value: String? = nil) {
        self.title = title
        self.symbol = symbol
        self.value = value
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(symbol: symbol)
                .font(.app(.subheadline))
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)
                .background(Color.ground, in: .rect(cornerRadius: 8))
            Text(title)
            Spacer(minLength: 8)
            if let value, !value.isEmpty { Text(value).foregroundStyle(.secondary) }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Swipe actions

/// A swipe action drawn as its icon alone, in `color`, on no background. The title stays for VoiceOver.
struct SwipeAction: View {
    let title: String
    let symbol: AppSymbol
    /// Nil uses the theme's accent.
    var color: Color?
    var role: ButtonRole?
    let action: () -> Void
    @Environment(\.theme) private var theme

    init(_ title: String, symbol: AppSymbol, color: Color? = nil, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.color = color
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Label {
                Text(title)
            } icon: {
                // Swipe actions draw a template icon in white; a pre-colored original image keeps its color.
                Image(uiImage: UIImage(symbol: symbol, configuration: UIImage.SymbolConfiguration(textStyle: .body))
                    .withTintColor(color.map { UIColor($0) } ?? theme.palette.accent, renderingMode: .alwaysOriginal))
            }
        }
        .labelStyle(.iconOnly)
        .tint(.clear)
    }
}

extension View {
    /// The trailing Delete swipe in the theme's style. With `onDelete` also set, Edit mode keeps its delete control.
    func deleteSwipe(_ action: @escaping () -> Void) -> some View {
        swipeActions { SwipeAction("Delete", symbol: .delete, color: .statusError, role: .destructive, action: action) }
    }
}

extension UIFont {
    static func app(_ style: Font.TextStyle, weight: Font.Weight = .regular, size: CGFloat? = nil) -> UIFont {
        scaled(Theme.current.typography.sans, design: .default, style, weight, size)
    }

    static func mono(_ style: Font.TextStyle, weight: Font.Weight = .regular, size: CGFloat? = nil) -> UIFont {
        scaled(Theme.current.typography.mono, design: .monospaced, style, weight, size)
    }

    private static func scaled(_ family: FontFamily?, design: UIFontDescriptor.SystemDesign, _ style: Font.TextStyle,
                               _ weight: Font.Weight, _ size: CGFloat?) -> UIFont {
        let size = size ?? style.defaultSize
        let base: UIFont
        if let family, let font = UIFont(name: family.face(weight), size: size) {
            base = font
        } else {
            let system = UIFont.systemFont(ofSize: size, weight: weight.uiKit)
            base = system.fontDescriptor.withDesign(design).map { UIFont(descriptor: $0, size: size) } ?? system
        }
        // The theme's text size, when set, wins over the system's.
        let traits = Theme.current.textSize.map { UITraitCollection(preferredContentSizeCategory: $0.category) }
        return UIFontMetrics(forTextStyle: style.uiKit).scaledFont(for: base, compatibleWith: traits)
    }
}

extension UIConfigurationTextAttributesTransformer {
    /// Sets a UIButton configuration's title font; `titleLabel.font` is ignored once a button has a configuration.
    static func themed(_ font: UIFont) -> Self {
        Self { attributes in
            var attributes = attributes
            attributes.font = font
            return attributes
        }
    }
}

extension Font.TextStyle {
    var uiKit: UIFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .callout: .callout
        case .subheadline: .subheadline
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}


extension Font.Weight {
    var uiKit: UIFont.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}


/// Rounds grouped list sections with the theme's corner radius instead of iOS 26's 26 points.
/// SwiftUI has no API for it. Its list cells round their first and last rows with a `UICornerConfiguration`, so the
/// cell's setter swaps large fixed radii for the theme's, keeping which corners are rounded. Cells on screen are
/// remembered so a new radius reaches them at once.
@MainActor
enum ListCorners {
    private static var installed = false
    private static let cells = NSHashTable<UIView>.weakObjects()
    private static let selector = NSSelectorFromString("setCornerConfiguration:")
    private typealias Setter = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
    private static var original: Setter?

    /// Which corners the system rounded on a cell, kept so the radius can change later.
    private struct Rounded {
        var topLeft, topRight, bottomLeft, bottomRight: Bool
    }

    private static var rounded: [ObjectIdentifier: Rounded] = [:]

    /// iPad only; iPhone keeps the system's rounding.
    static var isAvailable: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    static func install() {
        guard #available(iOS 26, *), isAvailable, !installed, let method = class_getInstanceMethod(UIView.self, selector) else { return }
        installed = true
        let setter = unsafeBitCast(method_getImplementation(method), to: Setter.self)
        original = setter
        let block: @convention(block) (UIView, AnyObject?) -> Void = { view, configuration in
            guard let configuration, NSStringFromClass(type(of: view)).hasSuffix("ListCollectionViewCell"),
                  let corners = roundedCorners(configuration) else {
                setter(view, selector, configuration)
                return
            }
            cells.add(view)
            rounded[ObjectIdentifier(view)] = corners
            setter(view, selector, make(corners, radius: Theme.current.cornerRadius) ?? configuration)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    /// Applies the theme's radius to the cells on screen.
    static func refresh() {
        guard #available(iOS 26, *), let original else { return }
        for view in cells.allObjects {
            guard let corners = rounded[ObjectIdentifier(view)] else { continue }
            guard let configuration = make(corners, radius: Theme.current.cornerRadius) else { return }
            original(view, selector, configuration)
        }
    }

    /// The corners with a section-sized fixed radius, read from the configuration's description, which lists each
    /// corner as `fixed(radius: …)` or `unspecified`. Nil when none qualify, so other shapes pass through.
    private static func roundedCorners(_ configuration: AnyObject) -> Rounded? {
        let text = String(describing: configuration)
        func large(_ corner: String) -> Bool {
            guard let range = text.range(of: "\(corner)Radius = fixed(radius: ") else { return false }
            let digits = text[range.upperBound...].prefix { "0123456789.".contains($0) }
            return (Double(digits) ?? 0) > 16
        }
        let corners = Rounded(topLeft: large("topLeft"), topRight: large("topRight"),
                              bottomLeft: large("bottomLeft"), bottomRight: large("bottomRight"))
        return corners.topLeft || corners.topRight || corners.bottomLeft || corners.bottomRight ? corners : nil
    }

    /// Built through the Objective-C class methods: the Swift `UICornerConfiguration` is a wrapper, not the object
    /// the setter takes.
    private static func make(_ corners: Rounded, radius: CGFloat) -> AnyObject? {
        guard let configurationClass = NSClassFromString("UICornerConfiguration"),
              let radiusClass = NSClassFromString("UICornerRadius") else { return nil }
        let fixedSelector = NSSelectorFromString("fixedRadius:")
        let cornersSelector = NSSelectorFromString("configurationWithTopLeftRadius:topRightRadius:bottomLeftRadius:bottomRightRadius:")
        typealias Fixed = @convention(c) (AnyClass, Selector, CGFloat) -> AnyObject
        typealias Corners = @convention(c) (AnyClass, Selector, AnyObject?, AnyObject?, AnyObject?, AnyObject?) -> AnyObject
        guard let fixedIMP = class_getMethodImplementation(object_getClass(radiusClass), fixedSelector),
              let cornersIMP = class_getMethodImplementation(object_getClass(configurationClass), cornersSelector) else { return nil }
        let fixed = unsafeBitCast(fixedIMP, to: Fixed.self)(radiusClass, fixedSelector, radius)
        func value(_ on: Bool) -> AnyObject? { on ? fixed : nil }
        return unsafeBitCast(cornersIMP, to: Corners.self)(configurationClass, cornersSelector, value(corners.topLeft),
                                                           value(corners.topRight), value(corners.bottomLeft),
                                                           value(corners.bottomRight))
    }
}

