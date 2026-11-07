import ProxyModel
import Storage
import SwiftUI

/// Every action on one flow, as the row's context menu.
struct FlowActions: View {
    @Environment(AppModel.self) private var model
    let flow: FlowRecord

    var body: some View {
        if model.canResend(flow) {
            Section {
                if model.tunnel.isRunning {
                    Button {
                        Task { if let error = await model.repeatFlow(flow) { model.alert = AppAlert(title: "Couldn’t Repeat Request", message: error) } }
                    } label: { Text("Repeat") }
                }
                Button { Task { await model.editAndRepeat(flow) } } label: {
                    Text("Edit and Repeat")
                }
            }
        }
        Section {
            CopyItems(flow: flow)
            if model.canResend(flow) { FlowShareMenu(flow: flow).labelStyle(.titleOnly) }
            if flow.kind != .dns {
                Menu { CreateRuleItems(flow: flow) } label: { Text("Create Rule") }
            }
        }
        Section {
            SelectItem(flow: flow)
            MarkItems(flow: flow)
        }
    }
}

/// Copy URL and the code generators.
struct CopyItems: View {
    @Environment(AppModel.self) private var model
    let flow: FlowRecord

    var body: some View {
        if let url = flow.url {
            Button("Copy URL") { UIPasteboard.general.string = url }
        }
        if model.canResend(flow) {
            Button {
                Task { model.codeSheet = CodeSheetRequest(request: await model.composedRequest(for: flow)) }
            } label: { Text("Copy as cURL, Swift…") }
        }
    }
}

/// Rules prefilled from this flow: for its URL, then for its host.
struct CreateRuleItems: View {
    @Environment(AppModel.self) private var model
    let flow: FlowRecord

    var body: some View {
        if model.canResend(flow) {
            Section("This URL") {
                ruleButton("Breakpoint…", .breakpoint)
                ruleButton("Map Local…", .mapLocal)
                ruleButton("Map Remote…", .mapRemote)
                ruleButton("Script…", .script)
                ruleButton("Block This URL…", .blockList)
                ruleButton("No Caching for This URL…", .noCaching)
            }
        }
        Section("Host") {
            ruleButton("Block Host…", .blockList, hostOnly: true)
            ruleButton("Throttle Host…", .networkConditions, hostOnly: true)
            ruleButton("Spoof DNS…", .dnsSpoof, hostOnly: true)
            if flow.kind == .https {
                if model.isDecrypting(flow.host) {
                    Button("Don’t Decrypt This Host") { model.stopDecrypting(flow.host) }
                } else {
                    Button("Decrypt This Host") { model.setSSLProxying(flow.host, true) }
                }
            }
        }
    }

    private func ruleButton(_ title: String, _ tool: RuleTool, hostOnly: Bool = false) -> some View {
        Button {
            Task { model.ruleDraft = await model.draft(tool, from: flow, hostOnly: hostOnly) }
        } label: { Text(title) }
    }
}

/// Picking two flows to compare.
/// Starts Select mode on the list with this flow selected, to compare or export several.
struct SelectItem: View {
    @Environment(AppModel.self) private var model
    let flow: FlowRecord

    var body: some View {
        Button { model.selectionRequest = SelectionRequest(flowID: flow.id) } label: {
            Text("Select")
        }
    }
}

/// Highlight color and comment.
struct MarkItems: View {
    @Environment(AppModel.self) private var model
    @AppStorage("lastMarkColor") private var lastColor = MarkColor.yellow
    let flow: FlowRecord

    var body: some View {
        let mark = model.marks[flow.id]
        Group {
            Menu {
                // A Picker gives the chosen color the system checkmark and selected state, which VoiceOver reads.
                Picker("Highlight", selection: Binding(get: { mark?.color }, set: { color in
                    if let color { lastColor = color }
                    model.setMark(FlowMark(color: color, comment: mark?.comment), for: flow.id)
                })) {
                    ForEach(MarkColor.allCases, id: \.self) { color in
                        Label {
                            Text(color.title)
                        } icon: {
                            // Menus drop SwiftUI tints, so the dot is a pre-colored image.
                            Image(uiImage: UIImage(symbol: .circleFill)
                                .withTintColor(UIColor(color.swiftUIColor), renderingMode: .alwaysOriginal))
                        }
                        .tag(Optional(color))
                    }
                }
                .pickerStyle(.inline)
                if mark?.color != nil {
                    Button("Remove Highlight") { model.setMark(FlowMark(color: nil, comment: mark?.comment), for: flow.id) }
                }
            } label: { Text("Highlight") }
            .menuOrder(.fixed)
            Button { model.commentTarget = flow } label: {
                Text(mark?.comment?.isEmpty == false ? "Edit Comment…" : "Add Comment…")
            }
        }
    }
}
