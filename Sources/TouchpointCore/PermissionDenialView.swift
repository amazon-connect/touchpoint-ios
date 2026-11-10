#if canImport(SwiftUI)
import SwiftUI

/// A denied permission shown as a product state, not an error: what is off, what still works, and
/// a Settings deep link. Voice uses it for the microphone.
///
/// The SDK never requests a permission itself; the host decides when to ask (`PermissionPolicy`).
public struct PermissionDenialView: View {
    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .body) private var spacing = 12
    @ScaledMetric(relativeTo: .body) private var inset = 16
    private let denial: PermissionDenial
    private let onContinueWithChat: (() -> Void)?

    /// - Parameter onContinueWithChat: offered for a microphone denial, where chat remains available.
    public init(denial: PermissionDenial, onContinueWithChat: (() -> Void)? = nil) {
        self.denial = denial
        self.onContinueWithChat = onContinueWithChat
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text(TouchpointStrings.permissionTitle(denial.permission))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(TouchpointStrings.permissionBody(denial.permission))
                .font(.body)
            HStack {
                if denial.consequence == .voiceUnavailableChatRemains, let onContinueWithChat {
                    Button(action: onContinueWithChat) { Text(TouchpointStrings.continueWithChat) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("touchpoint.permission.continueWithChat")
                }
                if let url = denial.settingsURL {
                    Button { openURL(url) } label: { Text(TouchpointStrings.openSettings) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("touchpoint.permission.openSettings")
                }
            }
        }
        .padding(inset)
    }
}
#endif
