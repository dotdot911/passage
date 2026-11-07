import SwiftUI

/// Buttons along the bottom of a pushed screen. iOS 17 and 18 get a drawn bar instead of the system bottom toolbar:
/// cancelling a swipe back to a screen without one leaves the navigation bar showing that screen's title and buttons.
struct BottomBar<Items: View>: ViewModifier {
    @Environment(AppModel.self) private var model
    @ViewBuilder let items: () -> Items

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26, *) {
                content
                    .safeAreaInset(edge: .bottom, spacing: 0) { BreakpointBanner(inBottomBar: true) }
                    .toolbar { ToolbarItemGroup(placement: .bottomBar, content: items) }
            } else {
                content.safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        BreakpointBanner(inBottomBar: true)
                        HStack(spacing: 16) { items() }
                            .labelStyle(.iconOnly)
                            .imageScale(.large)
                            .padding(.horizontal, 20)
                            .frame(minHeight: 49)
                            .frame(maxWidth: .infinity)
                            .background(.bar)
                            .overlay(alignment: .top) { Divider() }
                    }
                }
            }
        }
        .onAppear { model.bottomBarScreens += 1 }
        .onDisappear { model.bottomBarScreens -= 1 }
    }
}

extension View {
    func bottomBar<Items: View>(@ViewBuilder _ items: @escaping () -> Items) -> some View {
        modifier(BottomBar(items: items))
    }
}
