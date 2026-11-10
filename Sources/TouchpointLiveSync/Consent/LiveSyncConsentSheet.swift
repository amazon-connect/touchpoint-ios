#if canImport(SwiftUI)
import SwiftUI
import TouchpointCore

/// The SDK's default consent presentation (App Store 5.1.2(i)): what is shared, with whom, a link
/// to the policy, and two choices. Every string is in the String Catalog, every dimension
/// scales with text size, and the sheet cannot be dismissed without a decision — a swipe-away
/// is not consent, and it is not a denial either; the client stays `.held` and nothing is posted.
public struct LiveSyncConsentSheet: View {
    @Environment(\.touchpointTheme) private var theme
    @ScaledMetric(relativeTo: .body) private var spacing = 16
    @ScaledMetric(relativeTo: .body) private var inset = 20
    private let controller: LiveSyncConsentController

    public init(controller: LiveSyncConsentController) {
        self.controller = controller
    }

    public var body: some View {
        let prompt = controller.prompt
        VStack(alignment: .leading, spacing: spacing) {
            Text(TouchpointStrings.consentTitle)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text(TouchpointStrings.consentBody(data: prompt.dataDescription, recipient: prompt.recipient))
                .font(.body)
            if let url = prompt.privacyPolicyURL {
                Link(TouchpointStrings.consentPrivacyPolicy, destination: url)
                    .font(.body)
            }
            Spacer(minLength: 0)
            Button {
                Task { await controller.grant() }
            } label: {
                Text(TouchpointStrings.consentAllow).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("touchpoint.consent.allow")
            Button {
                Task { await controller.deny() }
            } label: {
                Text(TouchpointStrings.consentDecline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("touchpoint.consent.decline")
        }
        .padding(inset)
        .interactiveDismissDisabled()
    }
}

/// A revoke control for a settings screen or the support dock: visible only while consent is
/// granted, so the customer can stop sharing mid-call.
public struct LiveSyncConsentRevokeButton: View {
    private let controller: LiveSyncConsentController
    public init(controller: LiveSyncConsentController) { self.controller = controller }
    public var body: some View {
        if controller.decision == .granted {
            Button(role: .destructive) {
                Task { await controller.deny() }
            } label: {
                Text(TouchpointStrings.consentRevoke)
            }
            .accessibilityIdentifier("touchpoint.consent.revoke")
        }
    }
}

extension View {
    /// Presents the consent prompt when the controller says the customer must be asked, using the
    /// SDK's default sheet. The host substitutes its own copy with the `presentation:` overload.
    public func liveSyncConsent(_ controller: LiveSyncConsentController) -> some View {
        liveSyncConsent(controller) { LiveSyncConsentSheet(controller: $0) }
    }

    /// Presents the consent prompt with the host's own view — a bank's consent copy is reviewed by
    /// its legal team and the default will not match it. The substituted view receives the
    /// controller and must call `grant()` or `deny()`; until it does, nothing is posted.
    public func liveSyncConsent<Presentation: View>(
        _ controller: LiveSyncConsentController,
        @ViewBuilder presentation: @escaping (LiveSyncConsentController) -> Presentation
    ) -> some View {
        modifier(ConsentPresentationModifier(controller: controller, presentation: presentation))
    }
}

private struct ConsentPresentationModifier<Presentation: View>: ViewModifier {
    let controller: LiveSyncConsentController
    let presentation: (LiveSyncConsentController) -> Presentation

    func body(content: Content) -> some View {
        content
            // Keyed on the controller: a host that binds a new client (a new contact) passes a new
            // controller to the same view, and a plain `.task` would never load it, leaving the new
            // client's consent held with no prompt and nothing posted.
            .task(id: ObjectIdentifier(controller)) { await controller.load() }
            .sheet(isPresented: Binding(get: { controller.needsPrompt }, set: { _ in })) {
                presentation(controller)
                    .interactiveDismissDisabled()
            }
    }
}
#endif
