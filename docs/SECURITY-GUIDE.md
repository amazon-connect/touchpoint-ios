# Security guide for integrators

What the SDK protects, what it relies on your app and backend to do, and the switches that are
yours to set.

If you discover a potential security issue in this project, notify AWS Security through the
[vulnerability reporting page](https://aws.amazon.com/security/vulnerability-reporting/). Please do
**not** create a public GitHub issue.

## What your backend must do

The SDK holds no AWS credentials and calls no Connect control-plane API. Your backend
implements `TouchpointBackend`: it authenticates your user, calls `StartChatContact` /
`StartWebRTCContact`, and returns participant tokens and Live Sync credentials.

- **Authenticate every call.** Treat the endpoints behind `TouchpointBackend` like any
  authenticated API of yours: a caller who can reach them can start contacts on your instance.
- **Rotate Live Sync credentials from the backend.** By default the SDK keeps the credentials
  until less than 20% of their lifetime remains (to `expiresAt`; set
  `CredentialBroker(refreshFraction:)` to change it), or until the service refuses them, and then
  calls `liveSyncCredentials()` again, so a rotated key reaches the next socket without an app
  update. A socket that is already open keeps the key it opened with. If the refresh fails, the
  SDK keeps using the unexpired pair. `LiveSyncClient.rotateCredentials()` forces a fresh key at
  once and reconnects.
- **Allow-list outbound destinations.** If your backend places outbound calls for the app, dial
  only numbers you have verified belong to the user.
- **Keeping the participant token off the device (optional).** Pass a custom chat client to
  `ConnectChatTransport.live(…, customChatClient:)` to route every Participant Service call
  through your backend, as web's `customChatClient` does. Your `startChatContact` may then
  return no participant token. The connection token and socket URL still reach the device,
  because the chat SDK opens the socket itself. For sign-in, the client must also adopt
  `TouchpointSignInSocketProviding`. From chat SDK 3.0, the client's methods use the AWS SDK for
  Swift's types. The chat SDK's migration guide covers the change.

## Debug-only pieces

`DevelopmentBackend` takes literal Live Sync keys so you can try the SDK before a backend exists.
It is wrapped in `#if DEBUG` and does not exist in a release build. Never ship keys in an app.

## Data at rest

The transcript store lives in the directory you pass as `containerURL`. On iOS the SDK gives its
database file, `touchpoint.store`, `FileProtectionType.completeUntilFirstUserAuthentication`. The
SQLite journal files beside it get your app's default protection class, which is the same unless
you changed it. Message bodies, interactive content and citations are sealed with AES-GCM (256-bit,
CryptoKit) and bound to their message id. Metadata stays in the clear so the store can be queried:
contact ids, participant ids and roles, display names, server message ids and sequence numbers,
timestamps, and delivery state. The key is in the Keychain as `whenUnlockedThisDeviceOnly`; the
SDK permits no weaker class.

- **Pruning is yours to call.** Conversations idle longer than `retention` (default 30 days) are
  removed, with their stored chat credentials, when you call
  `session.pruneExpiredConversations()`. The SDK never prunes on its own, so call it at launch.
- **Wiping.** `session.deleteAllConversations()` removes every row, rotates the key and forgets
  every stored chat credential. End the active contact first.
- **Credentials on the device.** In the same Keychain class the SDK keeps each live chat's
  participant credentials (so `resume(contactID:)` works) and the current Live Sync key pair. Chat
  credentials go when the contact ends or its conversation is pruned or wiped. After a lost
  connection they stay, because the contact may still be live and `resume(contactID:)` can try
  again. A refresh replaces the Live Sync pair. Otherwise it stays until the service refuses it or
  you call `broker.invalidateLiveSyncCredentials()`.
- **Signing out.** `deleteAllConversations()` doesn't touch Live Sync. When the user signs out,
  also call `broker.invalidateLiveSyncCredentials()` and the consent controller's `reset()`. The
  consent decision is stored per deployment, not per user, so without `reset()` the next user on
  the device inherits it.

The key is deliberately not bound to
the Secure Enclave or biometrics. The Secure Enclave holds only P-256 private keys and cannot run
AES-GCM over the transcript without an extra key-wrapping layer. A biometric binding would prompt
for Face ID on every resume and fail outright in the background, where the SDK reconciles the
transcript. The local store is a rebuildable cache of what Connect holds; if you need biometric
gating, put it in front of your own UI.

## Data in transit

All endpoints are HTTPS or WSS, derived rather than configured. The SDK needs no ATS exception
and declares none. It does not pin certificates. Your backend's certificates rotate on your
schedule and AWS's endpoints on AWS's; a pin set inside a published library would break every
installed app on the next rotation, and the Connect chat, Chime and web Touchpoint SDKs pin
nothing either. iOS's trust store is not user-extensible without MDM or a jailbreak, and ATS
enforces modern TLS. If you need pinning for your own backend, it belongs in your app, where you
own the pins and their rotation.

**The Live Sync API key travels in the WebSocket URL's query string.** That is the Live Sync
protocol, not an SDK choice. So, in release builds:

- Don't enable verbose `URLSession`/CFNetwork logging.
- Don't route traffic through a logging proxy.
- Don't put a network-inspection SDK that records URLs in front of the SDK's traffic.

**The Live Sync protocol's names are the service's own.** The socket and its messages carry
field and host names such as `nlx-api-key` and `type=voice-plus`. They are not secrets and you
can't configure them. The key's value is what to protect.

## Permissions and consent

- **The SDK never asks for a permission on its own.** The default `PermissionPolicy` is `.never`,
  and your app decides when to ask for the microphone. The SDK needs no notification permission.
- **Live Sync posts nothing until the customer grants consent** (`ConsentDecision.held` by
  default). Revoking consent closes the socket and clears what was advertised. Granting consent
  again doesn't reopen the socket; call `connect()` after a re-grant. The receive-only
  action socket opens when the client is created, and its URL carries the Live Sync keys and the
  contact id. To keep it closed until consent, create the client with `autoConnect: false` and
  call `connect()` after the grant.
- **The caller drives the actions; consent does not gate them.** As on Touchpoint for the web, the
  assistant acts on what the customer asks for, by voice or text, through the actions the current
  screen declares. The SDK does not check consent when an action arrives. If no action may run
  before the grant, keep the action socket closed until then (`autoConnect: false`, above).
- **Calls stay out of the system Recents list** (`includesCallsInRecents = false`). The SDK
  registers no PushKit and receives no calls. Your app declares the `audio` and `voip` background
  modes, because CallKit refuses to start an outbound call without `voip`.

## Screen share

Screen share is off unless your app enables it. The agent must request a session, and the
customer must start it. It uses ReplayKit's in-app capture, so iOS shows its own consent prompt
and recording indicator. Only your app's window is captured, and the share stops when the app goes
to the background or the call ends. The SDK's only share control is on `TouchpointVoiceMiniRail`;
the full-screen `TouchpointVoiceView` has none.

Mark anything the agent should never see:

```swift
BalanceView().touchpointScreenShareRedacted()   // blacked out of every shared frame
PINEntryView().touchpointScreenShareSecure()    // blanks the whole frame while on screen
```

The UIKit equivalents are `TouchpointScreenShare.redact(_:)`, `secure(_:)` and `stop(_:)`. Marks
are held weakly, so a released view drops out. The mask is applied to each frame before it is
encoded. It fails closed: a frame in a pixel format it does not recognise is blanked entirely.
`touchpointScreenShareSecure()` is the iOS equivalent of Android's `FLAG_SECURE`. Use it for any
screen whose layout alone is sensitive.

## Live Sync actions

The actions declared in the view tree are all the assistant can do.

- **Declare only reversible actions.** An action is advertised only while its view is in the view
  tree, and the device acts only on what the view tree declares. Declare what the customer can undo:
  filling in a form, filtering, selecting, navigating. Never declare a payment, a transfer, a
  submission or anything else that can't be undone. Leave that last step to the customer's own tap
  in your UI.
- **`confirmationRequired: true` adds a prompt to a reversible action** the customer should see
  coming, such as turning on a balance alert. It does not make an irreversible action safe to
  declare.

```swift
.touchpointAction("set_balance_alert", description: "Turn on a low-balance alert",
                  confirmationRequired: true) { (p: BalanceAlert) in model.setAlert(p) }
```

Apply `.touchpointActionConfirmation(client)` once near the root. A held action runs only after
the customer taps **Allow**. Cancelling, a human agent joining (or any other suspension of
dispatch, such as a reconnect still being reconciled), the action's screen going away, the
contact ending, or consent being revoked drops it. A second gated action that arrives while one
is held is itself declined, and the first stays on screen. Each drop is reported through `onError`
(`actionHandlerFailed`, "declined by user") and counted in `diagnostics.declinedConfirmations`.
Allow checks the payload again against what is advertised at that moment; if the screen changed
the action so the payload no longer fits, Allow rejects it as `.invalidPayload` instead of
running it.
To use your own UI instead, set `onPendingConfirmationChange` and call `confirmPendingAction()` or
`cancelPendingAction()`. An aggregator that outlives a client must forward its `confirmations:`
callback to the current client.

**While a person is on the contact, nothing the assistant asks for runs.** Invocations are
dropped, not queued, and counted in `diagnostics.suppressedInvocations`; navigation frames are
dropped too (`diagnostics.unhandledNavigationFrames`).
"A person" is an agent, a supervisor, or any role the SDK doesn't recognise. Dispatch also pauses
after a dropped connection or a resume, until the transcript confirms who is present. It resumes
by itself when the last person leaves, so handing a contact back to the assistant needs no code.
`LiveSyncClient.onDispatchStateChange` reports each change, with a reason when dispatch pauses.
`session.events` delivers `.liveSyncDispatchChanged` with the reason for both directions,
including `.humanAgentLeft` and `.transcriptReconciled`. All of this needs the
client bound to the contact's session (`session:` or `attach(to:)`); without it there is no
pause. The assistant only reaches a contact through a contact flow block that invokes it, so in
Amazon Connect it is not on the contact while a transfer waits in a queue unless your queue or
transfer flow invokes it.

**Payloads are validated on the device.** The Live Sync engine does not check a payload against
the schema you advertise, and can invoke actions you did not advertise. So the client rejects,
before any handler, prompt or `invocations()` observer sees it:

- an action that is not in the context you last advertised (with `sendContext`, or the view tree);
- a payload that does not match that action's schema, or any non-empty payload for an action
  advertised without one.

Names match exactly. A `null` for a property whose `type` does not include `"null"` counts as not
sent.

Each rejection is reported through `onError` as `.invalidPayload(action:description:)` (the
description names the schema keyword and a JSON Pointer, never a value) and counted in
`diagnostics.rejectedInvocations`. The validator supports a strict subset of JSON Schema: `type`,
`enum`, `const`, `properties`, `required`, `additionalProperties`, `items` (one schema),
`minItems`/`maxItems`, `minLength`/`maxLength`, `minimum`/`maximum`,
`exclusiveMinimum`/`exclusiveMaximum` and `format: "date"`; `title`, `description` and the like are
ignored. It **fails closed**: any other keyword (`pattern`, `oneOf`, `$ref`, other formats…) makes
every invocation of that action fail, and the client reports `.invalidConfiguration` when you
advertise it. The client also warns about a top-level property named `items` or `value`, which
the engine unwraps.
Every type-specific keyword needs a `type` beside it (`{"minimum": 0}` alone is unsupported). The
client also warns when you advertise a node without `type` (unless it is an `enum` or `const` of
strings), a `type` array or `type: "null"`: the engine always sends those as strings. Keep schemas tight (`additionalProperties: false`, `enum` for
closed sets), and still check business rules — amounts, ownership — in the handler. The assistant
is not told about a rejection (the action socket is receive-only), so it may believe the action
ran.

If your aggregator is not bound to the client (`TouchpointActionAggregator(confirmations:post:)`),
set the client's `onAction` to the aggregator's `route(_:)` and its `onContextNeeded` to
`readvertise()`, and call `readvertise()` after switching clients. Consent granted again after a
denial (the SDK's own sheet can do that) leaves the client with no context, and until it is sent
again every invocation is rejected as not advertised.

## Sign-in (Connect's Authenticate Customer)

- **Redirect URI type.** Use a custom URL scheme, or an `https` universal link on iOS 17.4 or later.
  An `https` redirect fails with `invalidConfiguration` on earlier iOS versions; the SDK does not
  fall back to a scheme.
- **Universal-link setup.** For `https`, your app must own the domain, and its
  `apple-app-site-association` must list the app under `webcredentials`.
- **Validation.** The SDK always uses an ephemeral web-authentication session, so it doesn't share
  the browser's cookies. It accepts a callback only when its scheme, host and path match yours and
  its `state` matches the one Connect issued. Your backend exchanges the code.
- **Scheme hijacking.** Another app can register the same custom scheme. The `state` check means
  that app can only make sign-in fail, but prefer `https` once your floor allows it.

## New-message notifications

The SDK posts no notifications and sends no device token anywhere. It reports each new
message from the other side through `TouchpointSession.onIncomingMessages`, and your app decides
what to do with it.

- **Keep message text off the lock screen.** A local notification's title and body show on a
  locked phone. Post generic text such as "You have a new message from support", not
  `message.body`.
- **Consent:** ask for notification permission in context, never as a condition of using chat (App
  Store guideline 4.5.4). Chat works without notifications.
- **Route the tap to the right conversation.** Put the contact id in the notification's `userInfo`.
  On tap, if the app was relaunched since, call `resume(contactID:)` rather than starting a new
  contact.
- **Expect nothing while suspended.** The handler runs only while the app runs. Replies missed while
  suspended are reported after the app returns and reconnects, normally as one `.catchUp` call.

## Connect Views (guides)

The guide renderer runs only for an `https` Amazon Connect instance URL (`*.my.connect.aws` or
`*.awsapps.com`); look-alike hosts are rejected. Its content-security policy allows scripts only
from your instance and from the page's own boot script, which carries a per-page nonce. A
navigation to any other origin is blocked. Pass your instance URL, never one built from user input.

## Security events your app can observe

| Event | Where it arrives |
|---|---|
| Sign-in redirect or `state` mismatch | `session.events` → `.failed(.invalidConfiguration)` |
| `https` sign-in redirect below iOS 17.4 | the SDK's sign-in card shows the sign-in as failed; a host that calls `session.beginAuthentication()` itself gets `.invalidConfiguration` thrown |
| Guide renderer instance URL rejected | thrown by `ConnectViewRendering(instanceURL:)` |
| Guide navigation to a foreign origin blocked | `session.events` → `.failed(.invalidConfiguration)` |
| Live Sync action not advertised, or payload not matching its schema | `LiveSyncClient.onError` → `.invalidPayload`; `diagnostics.rejectedInvocations` |
| Live Sync schema outside the supported subset, at advertise time | `LiveSyncClient.onError` → `.invalidConfiguration` |
| Live Sync handler failure (decode or the handler's own check) | `LiveSyncClient.onError` → `.actionHandlerFailed` |
| Live Sync malformed frame | `LiveSyncClient.onError` → `.malformedInvocation` |
| Gated action declined or dropped | `LiveSyncClient.onError` → `.actionHandlerFailed("declined by user")`; `diagnostics.declinedConfirmations` |
| Invocation dropped while dispatch is paused (a person on the contact, or reconciling after a reconnect) | `diagnostics.suppressedInvocations`; `onDispatchStateChange` reports the pause itself |
| Live Sync context withheld because consent was denied | `LiveSyncClient.onError` → `.consentNotGranted`, once per decision (nothing while consent is still held) |
| Unreadable stored messages skipped | `ConversationStore.undecryptableRowsSkipped` |

The sign-in and guide-navigation rows are reported only while the contact is live, and the
guide-navigation event comes from `TouchpointChatView` (and `.touchpointChat`).

Errors' `description` and `debugDescription`, which string interpolation and `print` use, are
redacted: no tokens, response bodies or query strings. Two places do carry a server response body:
the `responseBody` value of `TouchpointError.httpFailure` and `LiveSyncError.httpFailure`, and
`LiveSyncError`'s `localizedDescription`. Don't log those verbatim. The SDK writes nothing to the
system log and sends no telemetry, and it keeps the chat SDK's own reporting off; don't turn on the
chat SDK's `SDKLogger.isLoggingEnabled` in release builds. Forward these events to your own
monitoring if you want them.

## Dependencies

The SDK's direct dependencies are AWS-published packages:

- `amazon-connect-chat-ios`, consumed as source. It brings the AWS SDK for Swift (`aws-sdk-swift`,
  `smithy-swift`, `aws-crt-swift`) and the Swift packages those depend on, also as source.
- The Amazon Chime SDK `no-video-codecs` package. It ships binary frameworks whose SHA-256
  checksums are declared in that package's manifest, and SwiftPM verifies them on download. Your
  app's own `Package.resolved` pins the package revision.

`smithy-swift` includes a build plugin that runs on your build machine while Xcode compiles the AWS
SDK for Swift. Xcode asks you to trust and enable the plugin before it runs. Review it as you would
any build-time code. `xcodebuild -skipPackagePluginValidation` skips that check for every plugin in
your package graph, so use it only on build machines whose package graph you control.

The chat SDK sends Participant Service requests unsigned. The participant or connection token
authorises them, as the service expects. The chat SDK gives the AWS SDK for Swift empty placeholder
credentials, so the AWS SDK never looks for credentials on the device.

`Package.swift` declares minimum versions. If your app pins one of these packages below its
minimum, resolution fails with an error naming both versions. Every product ships a privacy
manifest.

Linking a product merges its dependencies' privacy declarations into your app's privacy report,
alongside the SDK's own. None is linked to the user and none tracks. Account for every one in your
App Store privacy details:

| Product | Declared by | Declaration |
|---|---|---|
| `TouchpointChat` | `AWSClientRuntime` | Other diagnostic data, for app functionality |
| `TouchpointChat` | `aws-crt-swift` | File-timestamp API access (reason `0A2A.1`) |
| `TouchpointChat` | `amazon-connect-chat-ios` | Attachments, for app functionality; product interaction, for analytics and app functionality |
| `TouchpointVoice` | Amazon Chime SDK | Performance data (battery, charging state, low-memory warnings) during calls |
| `TouchpointVoice` | Amazon Chime SDK media | File-timestamp API access (`C617.1`); system boot time (`35F9.1`) |
| `TouchpointLiveSync` | this SDK | Product interaction, for app functionality |
