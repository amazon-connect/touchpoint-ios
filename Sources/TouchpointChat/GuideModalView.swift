#if canImport(UIKit) && canImport(WebKit)
import SwiftUI
import UIKit
import WebKit
import TouchpointCore

// The guide renderer's `WKWebView` glue. Deliberately thin: every decision it makes —
// the origin to lock to, the HTML it loads, the payload it hands the renderer, which navigations to
// allow, and how to read a posted message — comes from the pure, unit-tested helpers in
// `ConnectViewRendering.swift`. This file only wires those into a web view and a sheet, which is the
// part that cannot be exercised without a running app (hence the integrator verifies it on device).

/// The full-screen sheet opened from a guide card: a title bar, and Amazon Connect's own view
/// renderer hosted in a locked-down `WKWebView`. An `onAction` from the renderer submits the view,
/// marks the card complete, and dismisses — web's `GuideModal` `handleAction` order exactly.
@MainActor
struct GuideModalView: View {
    @Environment(\.touchpointTheme) private var theme

    let title: String
    let viewName: String?
    let definition: ConnectViewDefinition
    let viewData: Data?
    let rendering: ConnectViewRendering
    let onSubmit: @MainActor (_ viewName: String?, _ action: String, _ data: Data) -> Void
    let onComplete: @MainActor () -> Void
    let onClose: @MainActor () -> Void
    /// Report a refused foreign-origin navigation to the host's error stream (I6). `nil` ⇒ not wired.
    var onSecurityRejection: (@MainActor (TouchpointError) -> Void)?

    @State private var state: LoadState = .loading
    enum LoadState { case loading, ready, failed }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                GuideWebView(
                    definition: definition,
                    viewData: viewData,
                    rendering: rendering,
                    onAction: { action, data in
                        // Submit, then complete, then close — web's `handleAction` order.
                        onSubmit(viewName, action, data)
                        onComplete()
                        onClose()
                    },
                    onReady: { state = .ready },
                    onError: { if state != .ready { state = .failed } },
                    onSecurityRejection: onSecurityRejection)
                    .opacity(state == .ready ? 1 : 0)
                    .accessibilityHidden(state != .ready)

                if state == .loading {
                    ProgressView()
                        .accessibilityLabel(TouchpointStrings.guideLoading)
                } else if state == .failed {
                    Text(TouchpointStrings.guideError)
                        .font(TranscriptMetrics(scale: 1, theme: theme).bodyFont)
                        .foregroundStyle(theme.error)
                        .padding()
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(TouchpointSurface())
        .touchpointTheme(theme)
    }

    private var header: some View {
        let metrics = TranscriptMetrics(scale: 1, theme: theme)
        return HStack(alignment: .center, spacing: metrics.controlPadding) {
            Text(title)
                .font(metrics.bodyFont.weight(.semibold))
                .foregroundStyle(theme.primary(.t90))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button { onClose() } label: {
                TouchpointIconView(.close, size: metrics.compactIconGlyphSize)
                    .foregroundStyle(theme.primary(.t60))
                    .frame(width: metrics.iconButtonDiameter, height: metrics.iconButtonDiameter)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(TouchpointStrings.guideClose)
        }
        .padding(.horizontal, metrics.controlPaddingWide)
        .padding(.vertical, metrics.controlPadding)
    }
}

/// The locked-down web view that hosts `<connect-view-renderer>`. Security posture, all from the
/// pure helpers: ephemeral (`nonPersistent`) data store so nothing is written to disk; the page is
/// loaded as an in-memory HTML string whose base URL is the instance origin (no `file://`, so no
/// local-file access); every frame navigation is checked against the instance origin and anything
/// else is cancelled; the single JS→native handler only accepts the validated, size-capped message
/// shape; and the `viewToken` never reaches the page — only `Content`/`InputData` do.
@MainActor
struct GuideWebView: UIViewRepresentable {
    let definition: ConnectViewDefinition
    let viewData: Data?
    let rendering: ConnectViewRendering
    let onAction: @MainActor (String, Data) -> Void
    let onReady: @MainActor () -> Void
    let onError: @MainActor () -> Void
    var onSecurityRejection: (@MainActor (TouchpointError) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(allowedOrigin: rendering.origin, onAction: onAction, onReady: onReady, onError: onError,
                    onSecurityRejection: onSecurityRejection)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()          // nothing persists to disk
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: GuideRenderer.messageHandlerName)
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        let origin = rendering.origin
        guard let scriptURL = GuideRenderer.scriptURL(origin: origin), let base = URL(string: origin) else {
            onError()
            return webView
        }
        let payload = GuideRenderer.payloadJSON(definition: definition, inputData: viewData)
        let html = GuideRenderer.htmlShell(origin: origin, scriptURL: scriptURL, payloadJSON: payload)
        webView.loadHTMLString(html, baseURL: base)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: GuideRenderer.messageHandlerName)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private let allowedOrigin: String
        private let onAction: @MainActor (String, Data) -> Void
        private let onReady: @MainActor () -> Void
        private let onError: @MainActor () -> Void
        private let onSecurityRejection: (@MainActor (TouchpointError) -> Void)?

        init(allowedOrigin: String, onAction: @escaping @MainActor (String, Data) -> Void,
             onReady: @escaping @MainActor () -> Void, onError: @escaping @MainActor () -> Void,
             onSecurityRejection: (@MainActor (TouchpointError) -> Void)? = nil) {
            self.allowedOrigin = allowedOrigin
            self.onAction = onAction
            self.onReady = onReady
            self.onError = onError
            self.onSecurityRejection = onSecurityRejection
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            // Status frames (`{Type:"ready"|"error"}`) drive the loading UI; everything else must be
            // the validated action shape or it is ignored.
            if let dict = message.body as? [String: Any], let type = dict["Type"] as? String {
                if type == "ready" { onReady() } else if type == "error" { onError() }
                return
            }
            guard let action = GuideBridge.parse(message.body) else { return }
            onAction(action.action, action.data)
        }

        // The async form: the closure form's handler type has changed across SDKs (`@MainActor
        // @Sendable`), and a near-miss is silently never called — which would leave navigation
        // unrestricted. This is the security boundary, so it must be the exact requirement.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            switch GuideNavigation.decide(url: navigationAction.request.url, allowedOrigin: allowedOrigin) {
            case .allow: return .allow
            case .cancel:
                // Defense in depth already blocks it; also surface the refusal so a host security
                // log records an attempt to drive the renderer off its locked origin (I6). The URL
                // itself is not forwarded — only a non-sensitive reason.
                onSecurityRejection?(.invalidConfiguration("guide renderer blocked a navigation to a foreign origin"))
                return .cancel
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) { onError() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) { onError() }
    }
}
#endif
