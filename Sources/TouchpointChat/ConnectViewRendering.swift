import Foundation
import TouchpointCore

// Connect Views / step-by-step Guides — the guide renderer.
//
// Opening a guide means hosting Amazon Connect's own view renderer, a remote script served by the
// customer's Connect instance, inside a `WKWebView`. That is remote code, so every part of it that
// can be reasoned about without a web view lives here as pure, platform-neutral, unit-tested code:
// which instance origin is acceptable, the renderer script URL, the local HTML shell, the payload
// the renderer is handed (which never contains the viewToken), the navigation policy, and the
// JS→native bridge message. The thin `WKWebView` glue is in `GuideModalView.swift`.

/// Host configuration that turns on the guide renderer. Mirrors how ``ChatAuthentication`` is
/// configured: the host supplies its Amazon Connect instance URL, which is validated up front.
///
/// Without this configured, a guide card keeps today's behaviour — it shows the form's heading and
/// a note that it continues with an agent, and tapping it does nothing (no crash).
///
/// Only an **https** URL whose host is an Amazon Connect instance — ending in `.my.connect.aws`
/// (e.g. `https://your-instance.my.connect.aws`) or `.awsapps.com` — is accepted; anything else
/// throws, because the renderer script and all guide navigation are locked to this one origin.
public struct ConnectViewRendering: Sendable, Equatable {
    public let instanceURL: URL

    public init(instanceURL: URL) throws {
        guard ConnectViewOrigin.validated(instanceURL) != nil else {
            throw TouchpointError.invalidConfiguration(
                "ConnectViewRendering needs an https Amazon Connect instance URL (e.g. https://your-instance.my.connect.aws)")
        }
        self.instanceURL = instanceURL
    }

    /// Convenience for a host that has the instance URL as a string.
    public init(instanceURL string: String) throws {
        guard let url = URL(string: string) else {
            throw TouchpointError.invalidConfiguration("ConnectViewRendering instance URL is not a valid URL")
        }
        try self.init(instanceURL: url)
    }

    /// The validated origin (`https://host[:port]`) the renderer is loaded from and locked to.
    public var origin: String { ConnectViewOrigin.validated(instanceURL) ?? "" }
}

/// Which instance URLs the renderer may be loaded from, and the origin to lock it to.
enum ConnectViewOrigin {
    /// Amazon Connect instance hosts: the newer `*.my.connect.aws` and the classic `*.awsapps.com`.
    static let allowedHostSuffixes = [".my.connect.aws", ".awsapps.com"]

    /// The canonical origin `https://host[:port]` for an acceptable instance URL, or `nil`. Requires
    /// https, a host, and at least one label before an allowed suffix (so the bare apex, and a
    /// look-alike like `…my.connect.aws.evil.com`, are both rejected).
    static func validated(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), !host.isEmpty,
              allowedHostSuffixes.contains(where: { host.hasSuffix($0) && host.count > $0.count })
        else { return nil }
        var origin = "https://\(host)"
        if let port = url.port { origin += ":\(port)" }
        return origin
    }
}

/// The navigation policy for the guide web view: only the instance origin (and `about:blank`, which
/// WKWebView uses for the in-memory shell) may navigate the frame.
enum GuideNavigation {
    enum Decision: Equatable { case allow, cancel }

    /// **Deviation / choice:** a navigation to any other origin is **cancelled**, not opened in the
    /// system browser — the strictly safer option. The renderer loads its sub-resources same-origin;
    /// a top-level navigation elsewhere is never something the guide needs, so blocking it outright
    /// removes any chance of the embedded remote code driving the web view off to an arbitrary site.
    static func decide(url: URL?, allowedOrigin: String) -> Decision {
        guard let url else { return .cancel }
        if url.absoluteString == "about:blank" { return .allow }
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return .cancel }
        var origin = "\(scheme)://\(host)"
        if let port = url.port { origin += ":\(port)" }
        return origin == allowedOrigin ? .allow : .cancel
    }
}

/// The one message shape the page is allowed to post to native, validated and size-capped.
enum GuideBridge {
    /// A guide submit is a small JSON object; this cap defends the native side from a runaway or
    /// hostile page without affecting any real submit.
    static let maxMessageBytes = 64 * 1024

    struct Action: Equatable {
        /// The view action (e.g. "Submit"); web's `detail.Action ?? ""`.
        let action: String
        /// The renderer's output as a canonical JSON object; web's `detail.Output ?? detail.Data ?? {}`.
        let data: Data
    }

    /// Parse a posted message into an ``Action``, or `nil` if it is not the expected shape or is
    /// oversized. The body arrives either as a dictionary (`WKScriptMessage.body`) or a JSON string.
    /// An action message must carry a String `Action`; status messages (`{Type: …}`) are handled
    /// elsewhere and return `nil` here. `Data`/`Output` that is not an object becomes `{}`.
    static func parse(_ body: Any, maxBytes: Int = maxMessageBytes) -> Action? {
        let object: [String: Any]?
        switch body {
        case let dict as [String: Any]:
            object = dict
        case let string as String:
            guard string.utf8.count <= maxBytes else { return nil }
            object = (try? JSONSerialization.jsonObject(with: Data(string.utf8))) as? [String: Any]
        default:
            object = nil
        }
        guard let object else { return nil }
        if let encoded = try? JSONSerialization.data(withJSONObject: object), encoded.count > maxBytes { return nil }
        guard let action = object["Action"] as? String else { return nil }
        let rawOutput = object["Output"] ?? object["Data"]
        let output = (rawOutput as? [String: Any]) ?? [String: Any]()
        let data = (try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])) ?? Data("{}".utf8)
        return Action(action: action, data: data)
    }
}

/// Builds the renderer payload and the local HTML shell. Pure, so the exact bytes a web view would
/// be handed are asserted in unit tests.
enum GuideRenderer {
    /// The single native message-handler name the page posts to.
    static let messageHandlerName = "touchpointGuide"

    /// The renderer script the instance serves (web's `viewRenderer.ts:20-25`).
    static func scriptURL(origin: String) -> URL? {
        URL(string: origin + "/connectwidget/static/views/renderer/latest/index.js")
    }

    /// The `view` payload the `<connect-view-renderer>` element is given — web's `ViewPayload`
    /// (`GuideCard.tsx:ViewPayload`, `:289-306`): `{Content:{Actions, InputSchema, Template}, InputData}`.
    /// Assembled from the resolved definition and the runtime input data. The `viewToken` is
    /// deliberately **not** part of it — only `Content` and `InputData` ever reach the page.
    static func payloadJSON(definition: ConnectViewDefinition, inputData: Data?) -> Data {
        let template = (try? JSONSerialization.jsonObject(with: definition.template, options: [.fragmentsAllowed])) ?? [String: Any]()
        var content: [String: Any] = ["Actions": definition.actions, "Template": template]
        if let schemaData = definition.inputSchema,
           let schema = try? JSONSerialization.jsonObject(with: schemaData, options: [.fragmentsAllowed]) {
            content["InputSchema"] = schema
        }
        let input = inputData.flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) } ?? [String: Any]()
        let payload: [String: Any] = ["Content": content, "InputData": input]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// `<`/`>` inside a `<script type="application/json">` block, escaped to their JSON `\uXXXX`
    /// forms so no `</script>` sequence can break out of the block. The parsed JSON is identical.
    static func escapeForScriptBlock(_ json: String) -> String {
        json.replacingOccurrences(of: "<", with: "\\u003c").replacingOccurrences(of: ">", with: "\\u003e")
    }

    /// The local HTML shell loaded with `loadHTMLString(_:baseURL:)` (baseURL = the instance
    /// origin). It loads the instance's renderer script, mounts `<connect-view-renderer>` with the
    /// payload, and forwards the element's `onAction` events to the single native handler. The
    /// payload is embedded as an escaped JSON block — never interpolated into executable JS — and a
    /// Content-Security-Policy restricts every fetch to the instance origin. Scripts run only from
    /// the instance or as this page's own boot script, which carries a fresh per-page nonce: no
    /// `'unsafe-inline'` and no `'unsafe-eval'` for scripts — Connect's renderer bundle uses neither
    /// `eval` nor `Function` (checked against the live bundle, 2026-10-22). Styles keep
    /// `'unsafe-inline'`: the renderer injects `<style>` elements and inline style attributes.
    /// - Parameter nonce: Fresh per page in production; fixed only by tests.
    static func htmlShell(origin: String, scriptURL: URL, payloadJSON: Data, locale: String = "en_US",
                          nonce: String = UUID().uuidString.replacingOccurrences(of: "-", with: "")) -> String {
        let payload = escapeForScriptBlock(String(decoding: payloadJSON, as: UTF8.self))
        let script = scriptURL.absoluteString
        let handler = messageHandlerName
        let csp = [
            "default-src 'self' \(origin)",
            "script-src 'self' \(origin) 'nonce-\(nonce)'",
            "style-src 'self' \(origin) 'unsafe-inline'",
            "img-src 'self' \(origin) data: blob:",
            "font-src 'self' \(origin) data:",
            "connect-src 'self' \(origin)",
            "frame-ancestors 'none'",
            "base-uri 'none'",
            "form-action 'none'",
        ].joined(separator: "; ")
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <style>html,body{margin:0;padding:0;height:100%;background:transparent;-webkit-text-size-adjust:100%;font:-apple-system-body}#tp-root{height:100%}</style>
        </head>
        <body>
        <script type="application/json" id="tp-view">\(payload)</script>
        <div id="tp-root"></div>
        <script nonce="\(nonce)">
        (function(){
          function post(m){ try{ window.webkit.messageHandlers.\(handler).postMessage(m); }catch(e){} }
          function boot(){
            var view;
            try { view = JSON.parse(document.getElementById('tp-view').textContent); }
            catch(e){ post({Type:'error', Message:'payload'}); return; }
            var el = document.createElement('connect-view-renderer');
            el.setAttribute('guideParticipant','END_CUSTOMER');
            el.setAttribute('interactionMode','Actual');
            el.setAttribute('locale','\(locale)');
            try { el.setAttribute('view', JSON.stringify(view)); } catch(e){}
            el.addEventListener('onAction', function(ev){
              var d = (ev && ev.detail) ? ev.detail : {};
              post({ Action: (d.Action != null ? d.Action : ''), Output: (d.Output != null ? d.Output : (d.Data != null ? d.Data : {})) });
            });
            document.getElementById('tp-root').appendChild(el);
            post({Type:'ready'});
          }
          var s = document.createElement('script');
          s.src = '\(script)'; s.async = true;
          s.onload = function(){
            if (window.customElements && customElements.whenDefined) {
              customElements.whenDefined('connect-view-renderer').then(boot, function(){ post({Type:'error', Message:'define'}); });
            } else { boot(); }
          };
          s.onerror = function(){ post({Type:'error', Message:'load'}); };
          document.head.appendChild(s);
        })();
        </script>
        </body>
        </html>
        """
    }
}
