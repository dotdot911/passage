import SwiftUI

/// Finishes a task in a toolbar: the system checkmark on iOS 26, a bold word before.
struct ConfirmButton: View {
    var title: LocalizedStringKey = "Done"
    let action: () -> Void

    var body: some View {
        if #available(iOS 26, *) { Button(role: .confirm, action: action) } else { Button(title, action: action).bold() }
    }
}

/// Dismisses a sheet that has nothing to save: the system close mark on iOS 26, the word Done before.
struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        if #available(iOS 26, *) { Button(role: .close, action: action) } else { Button("Done", action: action) }
    }
}

/// Leaves an editor without saving: the system cancel mark on iOS 26, the word Cancel before.
struct CancelButton: View {
    let action: () -> Void

    var body: some View {
        if #available(iOS 26, *) { Button(role: .cancel, action: action) } else { Button("Cancel", action: action) }
    }
}

extension View {
    /// A sheet that edits bodies or code: the larger page size on iPad (iOS 18 and later); the same as any sheet on iPhone.
    func editorSheetSizing() -> some View {
        modifier(EditorSheetSizing())
    }
}

private struct EditorSheetSizing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18, *) { content.presentationSizing(.page) } else { content }
    }
}
