import ProxyModel
import SwiftUI

extension EnvironmentValues {
    /// True inside a split view, where a row selects its route into the next column instead of pushing it.
    @Entry var inSplitView = false
}

extension AppModel {
    /// The part of `path` the list column shows: the open host, when there is one.
    var listPath: [Route] {
        if case .domain? = path.first { return [path[0]] }
        return []
    }

    /// The route in the detail column of a split view, after the list part of `path`.
    var detailRoute: Route? { path.count > listPath.count ? path[listPath.count] : nil }

    /// Shows `route` in the next column of a split view: a host replaces the whole path, anything else replaces the detail.
    func select(_ route: Route) {
        if case .domain = route { path = [route] } else { path = listPath + [route] }
    }

    func isSelected(_ route: Route) -> Bool {
        switch (route, route.isDomain ? path.first : detailRoute) {
        case (.domain(let a), .domain(let b)?): a == b
        case (.flow(let a), .flow(let b)?): a.id == b.id
        default: false
        }
    }
}

extension Route {
    var isDomain: Bool { if case .domain = self { true } else { false } }
}

/// A list row that pushes its route on a stack and selects it into the next column of a split view.
struct RouteLink<Label: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.inSplitView) private var inSplitView
    let route: Route
    @ViewBuilder let label: () -> Label

    init(_ route: Route, @ViewBuilder label: @escaping () -> Label) {
        self.route = route
        self.label = label
    }

    var body: some View {
        if inSplitView {
            Button { model.select(route) } label: {
                label().frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(Rectangle().fill(.tint).opacity(model.isSelected(route) ? 0.18 : 0))
            .accessibilityAddTraits(model.isSelected(route) ? .isSelected : [])
        } else {
            NavigationLink(value: route, label: label)
        }
    }
}

/// The screen a Traffic route opens, on the stack or in the detail column.
struct RouteDestination: View {
    @Environment(AppModel.self) private var model
    let route: Route

    var body: some View {
        switch route {
        case .domain(let host): DomainFlowsView(host: host)
        case .flow(let flow): FlowDetailView(flow: model.live(flow))
        case .diff(let a, let b): DiffView(a: model.live(a), b: model.live(b))
        case .compose(let draft): RouteComposeEditor(draft: draft)
        }
    }
}

/// The Traffic tab: a stack in compact width, a split view in regular width.
struct TrafficTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var width: CGFloat = 0
    /// Every column stays on screen; the list is what the detail is picked from.
    @State private var columns = NavigationSplitViewVisibility.all

    /// Wide enough for hosts, requests and the detail side by side.
    private static let threeColumnWidth: CGFloat = 1180

    var body: some View {
        @Bindable var model = model
        Group {
            if sizeClass != .regular {
                NavigationStack(path: $model.path) {
                    FlowListView().navigationDestination(for: Route.self) { RouteDestination(route: $0) }
                }
            } else if width >= Self.threeColumnWidth && model.mode == .domain {
                NavigationSplitView(columnVisibility: $columns) {
                    FlowListView().navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
                        .toolbar(removing: .sidebarToggle)
                } content: {
                    Group {
                        if let host = model.openHost { DomainFlowsView(host: host) } else {
                            EmptyColumn("No Host Selected")
                        }
                    }
                } detail: {
                    TrafficDetailColumn(waitsForHost: true)
                }
                .navigationSplitViewStyle(.balanced)
                .environment(\.inSplitView, true)
            } else {
                NavigationSplitView(columnVisibility: $columns) {
                    NavigationStack(path: listPath) {
                        FlowListView().navigationDestination(for: Route.self) { RouteDestination(route: $0) }
                    }
                    .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 460)
                    .toolbar(removing: .sidebarToggle)
                } detail: {
                    TrafficDetailColumn()
                }
                .navigationSplitViewStyle(.balanced)
                .environment(\.inSplitView, true)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// The list column's own stack: only a host can be pushed on it, and changing the host clears the detail.
    private var listPath: Binding<[Route]> {
        Binding(get: { model.listPath }, set: { if $0 != model.listPath { model.path = $0 } })
    }
}

/// The selected request, and whatever it pushes (Diff, a repeated copy), in the detail column.
private struct TrafficDetailColumn: View {
    @Environment(AppModel.self) private var model
    /// Beside a host column, the column stays blank until a host is picked, so only one placeholder shows.
    var waitsForHost = false

    var body: some View {
        NavigationStack(path: tail) {
            Group {
                if let route = model.detailRoute {
                    RouteDestination(route: route)
                } else if waitsForHost && model.openHost == nil {
                    Color.ground.ignoresSafeArea()
                } else {
                    EmptyColumn("No Request Selected")
                }
            }
            .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
        }
        // A new selection starts a new stack instead of animating a pop.
        .id(model.detailRoute.map(Self.key))
    }

    private var tail: Binding<[Route]> {
        let head = model.listPath.count + 1
        return Binding(get: { Array(model.path.dropFirst(head)) },
                       set: { model.path = Array(model.path.prefix(head)) + $0 })
    }

    private static func key(_ route: Route) -> String {
        switch route {
        case .domain(let h): "d" + h
        case .flow(let f): "f" + f.id.uuidString
        case .diff(let a, let b): "x" + a.id.uuidString + b.id.uuidString
        case .compose: "c"
        }
    }
}

/// Reports whether the system draws this screen's bars vertically along a side, as iPhone Duo does in some poses.
struct VerticalBarsReader: ViewModifier {
    @Binding var isVertical: Bool

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) { content.modifier(Reader(isVertical: $isVertical)) } else { content }
    }

    @available(iOS 27.1, *)
    private struct Reader: ViewModifier {
        @Environment(\.toolbarVerticalEdge) private var edge
        @Binding var isVertical: Bool

        func body(content: Content) -> some View {
            content.onChange(of: edge != nil, initial: true) { isVertical = $1 }
        }
    }
}

/// A subtitle under the system title, where the system has one (iOS 26 and later).
struct NavigationSubtitle: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if #available(iOS 26, *), let text { content.navigationSubtitle(text) } else { content }
    }
}

extension View {
    /// Marks a task screen: when its toolbar and the tab bar share a vertical bar on iPhone Duo, the tab bar gives way.
    func prefersToolbarOverTabBar() -> some View {
        modifier(PrefersToolbar())
    }
}

private struct PrefersToolbar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) { content.toolbarVerticalCompressionBehavior(.prefersToolbarItems) } else { content }
    }
}

/// Keeps a form in a wide detail column to a readable width, centered, like the pages of the Settings app on iPad.
/// A frame rather than content margins, which would also reach the sheets this page presents.
struct ReadableWidth: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .background(Color.ground.ignoresSafeArea())
    }
}

extension View {
    func readableWidth() -> some View { modifier(ReadableWidth()) }
}

/// The usual 20-point side margins for one list in a detail column. On iPhone Duo the column runs under the list beside it
/// and under vertical bars, and the list's own margins vanish into that safe area. Apply it to each scroll view, since
/// the margins come from that view's own insets.
struct ColumnMargins: ViewModifier {
    @State private var insets = EdgeInsets()

    func body(content: Content) -> some View {
        content
            .contentMargins(.leading, insets.leading + 20, for: .scrollContent)
            .contentMargins(.trailing, insets.trailing + 20, for: .scrollContent)
            .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets = $0 }
    }
}
