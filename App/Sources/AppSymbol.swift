import SwiftUI

/// The app's icons. The theme's `IconSet` decides whether they draw as Lucide custom symbols or SF Symbols.
enum AppSymbol: String {
    case add
    case altRoute
    case arrowDownward
    case arrowUpward
    case block
    case cancel
    case cancelFill
    case chat
    case check
    case checkCircle
    case checkCircleFill
    case chevronRight
    case circle
    case circleFill
    case contentCopy
    case counter1
    case counter2
    case counter3
    case counter4
    case dangerous
    case dangerousFill
    case dataObject
    case databaseOff
    case delete
    case document
    case dns
    case editSquare
    case error
    case errorFill
    case eventBusy
    case hardDrive
    case info
    case filterAlt
    case filterAltFill
    case filterList
    case forum
    case gppBad
    case gppBadFill
    case inbox
    case inkHighlighter
    case iosShare
    case keyboardArrowDown
    case keyboardArrowUp
    case listAlt
    case listAltFill
    case lock
    case lockFill
    case lockOpen
    case memory
    case menuBook
    case moreHoriz
    case noEncryption
    case panelBottom
    case panelRight
    case pause
    case pauseCircle
    case pauseCircleFill
    case playArrow
    case playArrowFill
    case playCircle
    case refresh
    case schedule
    case search
    case send
    case sendFill
    case sensors
    case sensorsOff
    case settings
    case settingsFill
    case speed
    case star
    case sunMoon
    case starFill
    case terminal
    case tune
    case traffic
    case rules
    case verified
    case verifiedFill
    case verifiedUser
    case warning
    case warningFill

    /// The numbered circle for step `n` of a guide (1…4).
    static func counter(_ n: Int) -> AppSymbol { AppSymbol(rawValue: "counter\(n)") ?? .circle }

    /// The custom symbol's asset name; More is a plain ellipsis on iOS 26 and an ellipsis in a circle before.
    var name: String {
        if self == .moreHoriz, #unavailable(iOS 26) { return "moreHorizCircle" }
        return rawValue
    }

    var isSystem: Bool { Theme.current.icons == .sfSymbols }

    /// The SF Symbol for the same meaning.
    var systemName: String {
        if self == .moreHoriz, #unavailable(iOS 26) { return "ellipsis.circle" }
        return switch self {
        case .add: "plus"
        case .altRoute: "arrow.triangle.branch"
        case .arrowDownward: "arrow.down"
        case .arrowUpward: "arrow.up"
        case .block: "nosign"
        case .cancel: "xmark.circle"
        case .cancelFill: "xmark.circle.fill"
        case .chat: "text.bubble"
        case .check: "checkmark"
        case .checkCircle: "checkmark.circle"
        case .checkCircleFill: "checkmark.circle.fill"
        case .chevronRight: "chevron.forward"
        case .circle: "circle"
        case .circleFill: "circle.fill"
        case .contentCopy: "doc.on.doc"
        case .counter1: "1.circle"
        case .counter2: "2.circle"
        case .counter3: "3.circle"
        case .counter4: "4.circle"
        case .dangerous: "xmark.octagon"
        case .dangerousFill: "xmark.octagon.fill"
        case .dataObject: "curlybraces"
        case .databaseOff: "externaldrive.badge.xmark"
        case .delete: "trash"
        case .document: "doc.text"
        case .dns: "network"
        case .editSquare: "square.and.pencil"
        case .error: "exclamationmark.octagon"
        case .errorFill: "exclamationmark.octagon.fill"
        case .eventBusy: "calendar.badge.exclamationmark"
        case .hardDrive: "internaldrive"
        case .info: "info.circle"
        case .filterAlt: "line.3.horizontal.decrease.circle"
        case .filterAltFill: "line.3.horizontal.decrease.circle.fill"
        case .filterList: "line.3.horizontal.decrease"
        case .forum: "bubble.left.and.bubble.right"
        case .gppBad: "xmark.seal"
        case .gppBadFill: "xmark.seal.fill"
        case .inbox: "tray"
        case .inkHighlighter: "highlighter"
        case .iosShare: "square.and.arrow.up"
        case .keyboardArrowDown: "chevron.down"
        case .keyboardArrowUp: "chevron.up"
        case .listAlt: "list.bullet.rectangle"
        case .listAltFill: "list.bullet.rectangle.fill"
        case .lock: "lock"
        case .lockFill: "lock.fill"
        case .lockOpen: "lock.open"
        case .memory: "memorychip"
        case .menuBook: "book"
        case .moreHoriz: "ellipsis"
        case .noEncryption: "lock.trianglebadge.exclamationmark"
        case .panelBottom: "rectangle.bottomhalf.inset.filled"
        case .panelRight: "sidebar.right"
        case .pause: "pause"
        case .pauseCircle: "pause.circle"
        case .pauseCircleFill: "pause.circle.fill"
        case .playArrow: "play"
        case .playArrowFill: "play.fill"
        case .playCircle: "play.circle"
        case .refresh: "arrow.clockwise"
        case .schedule: "clock"
        case .search: "magnifyingglass"
        case .send: "paperplane"
        case .sendFill: "paperplane.fill"
        case .sensors: "antenna.radiowaves.left.and.right"
        case .sensorsOff: "antenna.radiowaves.left.and.right.slash"
        case .settings: "gearshape"
        case .settingsFill: "gearshape.fill"
        case .speed: "tortoise"
        case .star: "star"
        case .sunMoon: "circle.lefthalf.filled"
        case .starFill: "star.fill"
        case .terminal: "terminal"
        case .tune: "slider.horizontal.3"
        case .traffic: "arrow.up.arrow.down"
        case .rules: "checklist"
        case .verified: "checkmark.seal"
        case .verifiedFill: "checkmark.seal.fill"
        case .verifiedUser: "checkmark.shield"
        case .warning: "exclamationmark.triangle"
        case .warningFill: "exclamationmark.triangle.fill"
        }
    }
}

extension Image {
    init(symbol: AppSymbol) {
        if symbol.isSystem { self.init(systemName: symbol.systemName) } else { self.init(symbol.name) }
    }
}

#if os(iOS)
extension UIImage {
    convenience init(symbol: AppSymbol, configuration: UIImage.SymbolConfiguration? = nil) {
        if symbol.isSystem {
            self.init(systemName: symbol.systemName, withConfiguration: configuration)!
        } else {
            self.init(named: symbol.name, in: nil, with: configuration)!
        }
    }
}
#endif

extension Label where Title == Text, Icon == Image {
    init(_ titleKey: LocalizedStringKey, symbol: AppSymbol) { self.init { Text(titleKey) } icon: { Image(symbol: symbol) } }

    /// An empty state's title; ContentUnavailableView would set the system font on a plain label.
    init(emptyState titleKey: LocalizedStringKey, symbol: AppSymbol) {
        self.init { Text(titleKey).font(.app(.title2, weight: .bold)) } icon: { Image(symbol: symbol) }
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, symbol: AppSymbol) { self.init { Text(title) } icon: { Image(symbol: symbol) } }
}

extension ContentUnavailableView where Label == SwiftUI.Label<Text, Image>, Description == Text?, Actions == EmptyView {
    init(_ titleKey: LocalizedStringKey, symbol: AppSymbol, description: Text? = nil) {
        self.init { Label(emptyState: titleKey, symbol: symbol) } description: { description?.font(.app(.body)) }
    }

    /// The system's empty search result, in the theme's type.
    init(searching text: String) {
        self.init { Label(emptyState: "No Results for “\(text)”", symbol: .search) } description: {
            Text("Check the spelling or try a new search.").font(.app(.body))
        }
    }
}

#if os(iOS)
@available(iOS 18, *)
extension Tab where Value: Hashable, Content: View, Label == DefaultTabLabel {
    init(_ titleKey: LocalizedStringKey, symbol: AppSymbol, value: Value, @ViewBuilder content: () -> Content) {
        if symbol.isSystem {
            self.init(titleKey, systemImage: symbol.systemName, value: value, content: content)
        } else {
            self.init(titleKey, image: symbol.name, value: value, content: content)
        }
    }
}
#endif
