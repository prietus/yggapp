import SwiftUI

/// Small shims so the same screens read naturally on iOS and macOS.
extension View {
    /// A text field for URIs/addresses: no auto-capitalization or autocorrect.
    func plainURLInput() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
        #else
        self.autocorrectionDisabled()
        #endif
    }

    /// macOS sheets size to their content's ideal size, and a List has none,
    /// so give sheets a real size there. No-op on iOS.
    func macSheetSize(width: CGFloat = 520, height: CGFloat = 640) -> some View {
        #if os(macOS)
        self.frame(minWidth: 440, idealWidth: width, minHeight: 420, idealHeight: height)
        #else
        self
        #endif
    }

    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

/// A settings-style list: inset grouped List on iOS, grouped Form on macOS.
struct SettingsList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        #if os(macOS)
        Form { content }.formStyle(.grouped)
        #else
        List { content }
        #endif
    }
}
