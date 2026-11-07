import SwiftUI

/// Light or dark, the accent color and the text size, saved in `ThemeStore`. Changes apply as they are made.
struct AppearanceView: View {
    @Environment(ThemeStore.self) private var store
    @Environment(\.dynamicTypeSize) private var currentSize

    var body: some View {
        @Bindable var store = store
        AppForm {
            Section {
                HStack(alignment: .top) {
                    ForEach(Appearance.allCases, id: \.self) { appearance in
                        AppearanceTile(appearance: appearance, palette: store.theme.palette,
                                       selected: store.theme.appearance == appearance) {
                            store.theme.appearance = appearance
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 8)
            } footer: {
                SectionFooter {
                    Text("Automatic switches between light and dark with the system.")
                }
            }

            Section {
                AccentPicker(palette: $store.theme.palette)
            } header: { Text("Accent Color") } footer: {
                SectionFooter {
                    Text("Buttons, links, switches and selections use this color.")
                }
            }

            if #available(iOS 26, *), ListCorners.isAvailable {
                Section {
                    HStack(spacing: 14) {
                        Slider(value: radiusStep, in: 0...Double(Self.radii.count - 1), step: 1) { Text("Corner Radius") }
                        Text("\(Int(store.theme.cornerRadius)) pt")
                            .font(.mono(.subheadline))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 44, alignment: .trailing)
                    }
                } header: { Text("Corner Radius") } footer: {
                    SectionFooter {
                        Text("The rounding of grouped rows like these. The system default is 26 pt.")
                    }
                }
            }

            Section {
                Toggle("Use System Text Size", isOn: followsSystem)
                if let index = store.theme.textSize?.index {
                    HStack(spacing: 14) {
                        Text("A").font(.app(.footnote)).dynamicTypeSize(.large).accessibilityHidden(true)
                        Slider(value: Binding(get: { Double(index) },
                                              set: { store.theme.textSize = TextSize(index: Int($0.rounded())) }),
                               in: 0...Double(TextSize.all.count - 1), step: 1) {
                            Text("Text Size")
                        }
                        Text("A").font(.app(.title2)).dynamicTypeSize(.large).accessibilityHidden(true)
                    }
                }
            } header: { Text("Text Size") } footer: {
                SectionFooter {
                    Text(store.theme.textSize == nil
                         ? "Text follows the size set in Display & Brightness."
                         : "Drag the slider to change the size of text in Passage.")
                }
            }
        }
        .navigationTitle("Appearance")
    }

    /// The corner radii the slider stops at, from square to the system's own 26 pt.
    private static let radii: [CGFloat] = [0, 4, 8, 12, 16, 20, 26]

    /// The slider's stop for the current radius; a radius between stops shows at the nearest one.
    private var radiusStep: Binding<Double> {
        Binding(get: {
            let radius = store.theme.cornerRadius
            let nearest = Self.radii.indices.min { abs(Self.radii[$0] - radius) < abs(Self.radii[$1] - radius) } ?? 0
            return Double(nearest)
        }, set: { store.theme.cornerRadius = Self.radii[Int($0.rounded())] })
    }

    /// Turning it off starts the slider at the size in use, so nothing jumps.
    private var followsSystem: Binding<Bool> {
        Binding(get: { store.theme.textSize == nil }, set: { follow in
            store.theme.textSize = follow ? nil : TextSize(index: TextSize.all.firstIndex(of: currentSize) ?? TextSize.large.index)
        })
    }
}

/// The preset accents in a row, then a color well for any other color.
private struct AccentPicker: View {
    @Binding var palette: Palette

    private struct Preset: Identifiable {
        let name: String
        /// Nil is the palette's own accent.
        let accent: AccentColor?
        var id: String { name }
    }

    private static let presets = [
        Preset(name: "Terracotta", accent: nil),
        Preset(name: "Ocean", accent: AccentColor(hex: 0x2F6FB5)),
        Preset(name: "Moss", accent: AccentColor(hex: 0x4F7A3A)),
        Preset(name: "Plum", accent: AccentColor(hex: 0x7A4B8F)),
        Preset(name: "Rose", accent: AccentColor(hex: 0xB5466B)),
        Preset(name: "Graphite", accent: AccentColor(hex: 0x4A4744)),
    ]

    var body: some View {
        HStack {
            ForEach(Self.presets) { preset in
                let selected = palette.customAccent == preset.accent
                Button { palette.customAccent = preset.accent } label: {
                    Circle()
                        .fill(color(preset))
                        .frame(width: 30, height: 30)
                        .padding(4)
                        .overlay { if selected { Circle().strokeBorder(color(preset), lineWidth: 2) } }
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(preset.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
                Spacer(minLength: 0)
            }
            ColorPicker("Custom Color", selection: custom, supportsOpacity: false)
                .labelsHidden()
                .padding(4)
                .overlay { if isCustom { Circle().strokeBorder(Color(uiColor: palette.accent), lineWidth: 2) } }
        }
        .padding(.vertical, 4)
    }

    private func color(_ preset: Preset) -> Color {
        Color(uiColor: Palette(name: palette.name, customAccent: preset.accent).accent)
    }

    private var isCustom: Bool {
        palette.customAccent != nil && !Self.presets.contains { $0.accent == palette.customAccent }
    }

    private var custom: Binding<Color> {
        Binding(get: { Color(uiColor: palette.accent) }, set: { palette.customAccent = AccentColor($0) })
    }
}

/// A miniature screen in light, dark, or split for Automatic, above its name and a selection mark.
private struct AppearanceTile: View {
    let appearance: Appearance
    let palette: Palette
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    MiniScreen(palette: palette, style: appearance == .dark ? .dark : .light)
                    if appearance == .automatic {
                        MiniScreen(palette: palette, style: .dark)
                            .mask(alignment: .trailing) { Rectangle().frame(width: 32) }
                    }
                }
                .frame(width: 64, height: 112)
                .overlay {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                                                                    lineWidth: selected ? 2 : 1)
                }
                Text(title).font(.app(.subheadline))
                Image(symbol: selected ? .checkCircleFill : .circle)
                    .font(.app(.title3))
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
        }
        .buttonStyle(.borderless)
        .tint(nil)
        .foregroundStyle(.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var title: LocalizedStringKey {
        switch appearance {
        case .automatic: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// A screen sketch in the palette's colors for one appearance: a title, two cards and an accent button.
private struct MiniScreen: View {
    let palette: Palette
    let style: UIUserInterfaceStyle

    var body: some View {
        let traits = UITraitCollection(userInterfaceStyle: style)
        let ink = Color(uiColor: UIColor.label.resolvedColor(with: traits))
        let card = Color(uiColor: palette.card.resolvedColor(with: traits))
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(uiColor: palette.ground.resolvedColor(with: traits)))
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    Capsule().fill(ink.opacity(0.8)).frame(width: 28, height: 5)
                    RoundedRectangle(cornerRadius: 4).fill(card).frame(height: 22)
                    RoundedRectangle(cornerRadius: 4).fill(card).frame(height: 30)
                    Capsule().fill(Color(uiColor: palette.accent.resolvedColor(with: traits))).frame(height: 10)
                }
                .padding(8)
            }
    }
}
