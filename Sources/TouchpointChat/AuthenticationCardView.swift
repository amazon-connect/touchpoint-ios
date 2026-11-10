import AuthenticationServices
import SwiftUI
import TouchpointCore

/// What the sign-in card does, set by the transcript and read by the card.
struct AuthenticationActions {
    var begin: (@MainActor () async throws -> AuthenticationRequest)?
    var complete: (@MainActor (URL) async throws -> Void)?
    var cancel: (@MainActor () async -> Void)?
}

extension EnvironmentValues {
    @Entry var touchpointAuthenticationActions = AuthenticationActions()
}

/// Web's `Authentication.tsx`: the heading, then a bordered box holding either the two actions
/// (prompt) or one status line with its icon.
///
/// The sign-in runs in the system's web-authentication sheet, **ephemeral**: Connect holds the PKCE
/// verifier, so a shared browser session would buy only single sign-on with other apps — a named
/// deviation from web's popup, which shares the browser's cookies. Closing the sheet, or any error
/// from it, cancels at once (web waits 400 ms only because its popup's message and close can race).
@MainActor
struct AuthenticationCardView: View {
    @Environment(\.touchpointTheme) private var theme
    @Environment(\.touchpointAuthenticationActions) private var actions
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let card: AuthenticationCard
    let metrics: TranscriptMetrics
    @State private var working = false
    @State private var pulsing = false

    private var failed: Bool { [.failed, .expired, .cancelled].contains(card.status) }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.controlPadding) {
            Text(TouchpointStrings.authenticationHeading)
                .font(metrics.bodyFont)
                .foregroundStyle(theme.primary(.t90))
                .accessibilityAddTraits(.isHeader)
            Group {
                if card.status == .prompt {
                    VStack(spacing: metrics.controlPadding) {
                        authenticateButton
                        if actions.cancel != nil {
                            Button { Task { await actions.cancel?() } } label: {
                                Text(TouchpointStrings.authenticationSkip)
                                    .font(metrics.captionFont)
                                    .foregroundStyle(theme.primary(.t60))
                                    .frame(maxWidth: .infinity, minHeight: metrics.minimumTapTarget)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .disabled(working)
                        }
                    }
                } else {
                    statusLine
                }
            }
            .padding(metrics.controlPadding)
            .overlay {
                TouchpointShape.rounded(metrics.outerRadius)
                    .strokeBorder(theme.primary(.t20), lineWidth: metrics.hairline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Web's `TextButton type="main"` with the forward arrow: ink fill, inverse label.
    private var authenticateButton: some View {
        Button { authenticate() } label: {
            Text(TouchpointStrings.authenticationAuthenticate)
        }
        .buttonStyle(TouchpointTextButtonStyle(.main, icon: .arrowForward))
        .disabled(working || actions.begin == nil)
    }

    private var statusLine: some View {
        HStack(spacing: metrics.controlPadding) {
            Group {
                switch card.status {
                case .success: TouchpointIconView(.check, size: metrics.iconGlyphSize)
                case .inProgress, .prompt:
                    Circle()
                        .frame(width: metrics.attachmentPulseDot, height: metrics.attachmentPulseDot)
                        .scaleEffect(pulsing && !reduceMotion ? 1.5 : 1)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: pulsing)
                        .onAppear { pulsing = true }
                default: TouchpointIconView(.error, size: metrics.iconGlyphSize)
                }
            }
            .accessibilityHidden(true)
            Text(TouchpointStrings.authenticationStatus(card.status))
                .font(metrics.bodyFont)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(failed ? theme.error : theme.primary(.t60))
        .frame(maxWidth: .infinity, minHeight: metrics.minimumTapTarget)
        .accessibilityElement(children: .combine)
    }

    /// Web's `startAuthentication` + `completeAuthentication`, through the system sheet.
    private func authenticate() {
        guard let begin = actions.begin, !working else { return }
        working = true
        Task {
            defer { working = false }
            let request: AuthenticationRequest
            do { request = try await begin() } catch { return }   // the card already says why
            let callback: URL
            do {
                // Custom scheme on any OS; https universal link on iOS 17.4+ (begin() has already
                // failed closed below that for an https redirect, so `.https` is never reached here
                // on an older OS).
                switch request.callback {
                case .scheme(let scheme):
                    callback = try await webAuthenticationSession.authenticate(using: request.url,
                                                                               callbackURLScheme: scheme,
                                                                               preferredBrowserSession: .ephemeral)
                case .https(let host, let path):
                    if #available(iOS 17.4, macOS 14.4, *) {
                        callback = try await webAuthenticationSession.authenticate(using: request.url,
                                                                                   callback: .https(host: host, path: path),
                                                                                   preferredBrowserSession: .ephemeral,
                                                                                   additionalHeaderFields: [:])
                    } else {
                        await actions.cancel?()
                        return
                    }
                }
            } catch {
                await actions.cancel?()   // closed, or it could not present: the flow goes on without
                return
            }
            try? await actions.complete?(callback)   // a failure is shown on the card
        }
    }
}
