# Amazon Connect Customer Touchpoint SDK for iOS

**Status: pre-release.** The public API will change without notice until a 1.0 release is tagged.

Native iOS SDK for Amazon Connect Customer Touchpoint: chat, outbound voice, and Live Sync, as
separately linkable Swift packages so an app pays only for the modalities it uses.

| Product | What it adds | Links |
| --- | --- | --- |
| `TouchpointCore` | Configuration, credential brokering, session coordination, durable store, theme tokens | — |
| `TouchpointChat` | Chat with an Amazon Connect contact and the transcript UI | `amazon-connect-chat-ios` |
| `TouchpointVoice` | Outbound WebRTC calling with CallKit | Amazon Chime SDK (no-video-codecs) |
| `TouchpointLiveSync` | Live Sync for a live chat or voice contact: declarative action context, on-device payload validation, consent and confirmation prompts | — |

A chat-only consumer never links the WebRTC media stack. `Scripts/check-build-graph.sh` enforces
that on every `make check` by walking the transitive product graph of every resolved package, so an
upstream dependency pulling Chime in would fail the gate too.

## Requirements

iOS 17.0+, Swift 6 language mode, Swift Package Manager. Xcode 26 or newer to build the iOS
products; the unit tier also runs on macOS 14+ with `swift test`.

## Installation

Add the package with Swift Package Manager and depend on the products you use:

```swift
dependencies: [
    .package(url: "https://github.com/amazon-connect/touchpoint-ios", from: "<release>"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "TouchpointChat", package: "touchpoint-ios"),
        .product(name: "TouchpointVoice", package: "touchpoint-ios"),       // only if you call
        .product(name: "TouchpointLiveSync", package: "touchpoint-ios"),    // only if you use Live Sync
    ]),
]
```

The package depends on the Connect chat SDK, which is built on the AWS SDK for Swift:

- Package resolution downloads the AWS SDK for Swift repository. It takes about 3 GB in SwiftPM's
  repository cache, plus about 500 MB for the checkout. In CI, keep that cache between runs.
- If your app also uses `amplify-swift`, use 2.55.0 or later. Earlier releases pin an older AWS SDK
  for Swift, and the package graph doesn't resolve.
- When you link `TouchpointChat`, Xcode builds the AWS SDK for Swift with a build plugin from
  `smithy-swift` and asks you to trust and enable the plugin. For `xcodebuild` in CI, pass
  `-skipPackagePluginValidation`. It trusts every package plugin in your graph (see the
  [security guide](docs/SECURITY-GUIDE.md#dependencies)). Also choose the platform with
  `-destination` (for example `-destination "generic/platform=iOS Simulator"`) rather than `-sdk`.

**Upgrading from a build on chat SDK 2.x.** `ConnectChatTransport.live(region:)` takes the chat
SDK's `Region` (`.usWest2`, or a string such as `"us-west-2"`). The older `.USWest2` spellings still
compile, with a deprecation warning. `live(regionName:)` is unchanged. A custom chat client
subclasses the chat SDK's `AWSClient`, whose methods now take and return the AWS SDK for Swift's
types. To update one, follow the chat SDK's 3.0 migration guide.

Your backend starts contacts and vends credentials; the SDK holds no AWS credentials. What your
app and backend must do, and the switches that are yours to set, are in the
[security guide](docs/SECURITY-GUIDE.md).

## Developer guide

The SDK is a client. The contact centre it talks to is yours: an Amazon Connect instance, its
contact flows and, for the assistant, an Agentic CX Designer application that a flow connects to. Most
integration problems come from that side, so each feature below ends with what it needs there.

### How the pieces fit

```
TouchpointBackend ─▶ CredentialBroker ─▶ TouchpointSession ◀─ ConversationStore
   (your server)                              │
                                     transports per modality
                              ConnectChatTransport · VoiceTransport
                                              │
                         SDK views: chat panel · voice view · call rail
```

- **One session holds one active contact.** Give chat and voice their own `TouchpointSession`
  over the same broker and store, so a call can start while a chat is open.
- **The store is the transcript cache.** It is encrypted at rest, survives relaunch, and lets
  `resume(contactID:)` reopen a conversation without starting a new contact.
- **Views, sessions, calls and the Live Sync client are `@MainActor`.** The backend, broker,
  store and transports are not.

### 1. Your backend

Implement `TouchpointBackend` against a service you run. It authenticates your user, calls
Amazon Connect and relays the result. Only the calls for the features you ship need to work;
throw `TouchpointError.invalidConfiguration("not supported")` from the rest.

```swift
import TouchpointCore

struct MyBackend: TouchpointBackend {
    let api: MyAPIClient   // your authenticated client for your own service

    func startChatContact(_ request: ChatContactRequest) async throws -> ChatContactCredentials {
        let r = try await api.startChat(displayName: request.displayName, attributes: request.attributes)
        // StartChatContact returns no expiry: the token lives as long as the contact.
        return ChatContactCredentials(contactID: r.contactId, participantID: r.participantId,
                                      participantToken: r.participantToken, expiresAt: nil)
    }

    func startVoiceContact(_ request: VoiceContactRequest) async throws -> VoiceContactCredentials {
        // Your service returns StartWebRTCContact's ConnectionData.Meeting and .Attendee as
        // `meeting` and `attendee`, beside contactId, participantId and participantToken.
        try VoiceContactCredentials(fromBackendReply: try await api.startVoice(request))
    }

    func liveSyncCredentials() async throws -> LiveSyncCredentials {
        let k = try await api.liveSyncKeys()
        return LiveSyncCredentials(deploymentKey: k.deploymentKey, apiKey: k.apiKey, expiresAt: k.expiresAt)
    }
}
```

What the backend must get right:

- **Authenticate every route.** Anyone who can call it can start contacts on your instance and
  use agent capacity.
- **Scope its IAM role to the instance and the flows it starts.** Grant `connect:StartChatContact`
  and `connect:StartWebRTCContact` on the instance ARN and each contact flow ARN, and
  `connect:UpdateParticipantAuthentication` on the instance if you use sign-in. Grant nothing else.
- **Choose the contact flow on the server.** The app sends a display name and attributes, never a
  flow or instance id. Attributes reach the flow as contact attributes, so bound their size and
  keep secrets out of them.
- **Pass `SupportedMessagingContentTypes`** to `StartChatContact`: `text/plain`, `text/markdown`,
  `application/json`, `application/vnd.amazonaws.connect.message.interactive` and
  `application/vnd.amazonaws.connect.message.interactive.response`. Without the last one, Connect
  rejects every choice the customer taps with a bare `ValidationException`.
- **Forward `VoiceContactRequest.clientToken` as `ClientToken`**, so a retried request doesn't
  start a second call.
- **Map Connect's `LimitExceededException` to a retryable error**, such as a 429. Contacts that
  are never ended count against the instance's concurrency limit.
- **Use a current AWS SDK.** Older ones, such as some bundled with Lambda runtimes, lack
  `StartWebRTCContact`.

`DevelopmentBackend` takes literal Live Sync keys so you can try Live Sync before your backend
exists. It is compiled into debug builds only.

### 2. Chat

```swift
import SwiftUI
import TouchpointChat
import TouchpointCore

@MainActor
func makeChatSession(backend: MyBackend) async throws -> TouchpointSession {
    let keychain = SecurityFrameworkKeychainStore(service: "com.example.myapp.touchpoint")
    let broker = CredentialBroker(backend: backend, keychain: keychain)
    let store = try await ConversationStore(
        containerURL: .applicationSupportDirectory.appending(path: "Touchpoint", directoryHint: .isDirectory),
        keychain: keychain)
    let chat = try ConnectChatTransport.live(regionName: "us-west-2")   // your instance's region
    return TouchpointSession(broker: broker, store: store, transports: [.chat: chat])
}

struct SupportButton: View {
    let session: TouchpointSession
    @State private var showChat = false

    var body: some View {
        Button("Chat with us") {
            showChat = true
            guard !session.isActive else { return }
            Task {
                do {
                    try await session.startChat(ChatContactRequest(displayName: "Jordan",
                                                                   attributes: ["screen": "accounts"]))
                } catch {
                    // Your backend refused or was unreachable: tell the customer.
                }
            }
        }
        .touchpointChat(session: session, isPresented: $showChat)
    }
}
```

- `.touchpointChat` presents the panel as a sheet. Use `TouchpointChatView` to place it yourself,
  or `.touchpointChatWindow(isPresented:mode:panel:)`, with a `TouchpointChatView` as the panel,
  for the full, half and mini window modes.
- The session reconnects on its own and resends unacknowledged messages. `end()` ends the contact.
  `resume(contactID:)` reopens a chat that is still live after a relaunch or a lost connection.
  Chats that ended any other way, and calls, can't be resumed.
- Pass `TouchpointChatActions` for the header's restart and settings controls and the built-in
  settings panel. Each control appears only when you set its hook. The panel offers restart
  (`onRestart`, disabled while a human agent is on a live chat), the transcript download, the end
  control (`onEndConversation`), and a window-mode picker when you set both `windowMode` and
  `onWindowModeChange`. `settingsRows` adds your own rows after the SDK's; a tap closes the panel,
  then runs the row's action. The header shows the settings button when the panel has more than
  restart and download to offer, or when you hide the header's restart. Set `onSettings` to show
  your own panel instead. `onContactEnded` tells you when a contact ends.
- Ending asks first, with a confirmation card drawn over the panel. On confirm, the panel (or, from
  the header close, the chat) closes at once and `onEndConversation` runs.

```swift
var actions = TouchpointChatActions(onRestart: { await restart() },
                                    onEndConversation: { await session.end() })
actions.settingsRows = [TouchpointSettingsRow(label: "Call us", isProminent: true) { startCall() }]
actions.onContactEnded = { reason in /* … */ }

TouchpointChatView(session: session,
                   header: ChatHeader(title: "Support", notice: "This chat is recorded."),
                   actions: actions,
                   onClose: { showChat = false },
                   options: TouchpointChatOptions(
                       hiddenElements: [.headerRestart],
                       addedElements: [.headerClose],
                       copy: TouchpointChatCopy(endConversationConfirm: .init(title: "End this chat?"))))
```

**Customising.** `TouchpointTheme` sets colours, corner radii, the surface style and the font.
`TouchpointChatOptions` matches the web SDK's options: bubbles, participant names and icons,
timestamps, the welcome screen and the header style. Pass them to the chat as `theme:` and
`options:`. `TouchpointChatView` and `.touchpointChat` apply their own values, so a
`.touchpointTheme(_:)` or `.touchpointChatOptions(_:)` placed outside them has no effect on the
chat. Use `.touchpointTheme(_:)` for the voice view and the call rail.

- `ChatHeader(title:closeStyle:notice:)` sets the title bar; `notice` adds a line under it.
- `hiddenElements` and `addedElements` match the web SDK's. Hide the header's restart (restart
  stays in the settings panel), its settings button (and with it the built-in panel), or the
  welcome logo. Add a header close after the minimise: with a chat that hasn't ended and an
  `onEndConversation`, it asks before it ends the conversation and closes the chat; otherwise it
  just closes. It needs an `onClose`, which `.touchpointChat` supplies.
- `copy` replaces the words of the end confirmation.
- The SDK ships its strings in English and the web SDK's eleven other languages, and follows the
  device language. `TouchpointCopy.languageCode` forces one, and `TouchpointCopy.setOverride(_:_:)`
  replaces any string by its key.

**Connect setup**

- You need an instance with chat enabled, an inbound chat contact flow, a queue, a routing profile
  that takes chat, and agents in that routing profile.
- Start the flow with a **Set logging behavior** block that enables flow logs. They are the
  quickest way to see where a contact went.
- Messages from **Send message** blocks appear as the assistant's.
- The chat socket runs only while the app runs. iOS suspends it a few seconds after the app goes
  to the background, and the session catches up from the server transcript when the app returns.

### 3. The assistant: choices, cards and custom modalities

Build the assistant in Agentic CX Designer and hand the contact to it with the contact flow's
**Agentic CX** flow block (`ConnectParticipantWithAgenticCX` in flow JSON). The SDK renders what the
assistant sends without any code from you: choices as suggested replies, the default modalities
(`DefaultCard`, `DefaultCarousel`, `DefaultDateInput`, `DefaultVideo`), interim "one moment"
lines, and markdown. Register a view for your own modality by name:

```swift
TouchpointChatView(session: session)
    .touchpointModality("OrderSummary") { context in
        OrderSummaryCard(json: context.modality.json, isEnabled: context.isEnabled) { confirmed in
            context.sendSlot("confirmed", confirmed ? "yes" : "no")
        }
    }
```

If your modality's name clashes with a default modality, the default wins.

**Agentic CX Designer setup**

- The block names a workspace, an application and an **alias**. If you set them by id (in flow
  JSON, `AgentConfiguration.WorkspaceId`, `ApplicationId` and `Alias`), `Alias` is the
  deployment's alias, not the environment name.
- Check that Agentic CX Designer and its flow block are available in your instance's Region.
- Context variables set in the block reach the application. Define them in the application
  first. A block takes up to 10. Pass what the assistant should know, such as the current screen.
- Contacts talk to the deployed build, so build and deploy the application after every change.
  If a new deployment gives you a new alias, update the block (and, for Live Sync, the
  deployment key your backend vends).
- When the block returns, the contact flow continues along its Default, Error, Idle chat timeout
  or Escalation branch. Route Escalation through **Set working queue** to **Transfer to queue**
  for a human agent, and give every branch an ending, or the conversation stops with no
  explanation.

### 4. Sign-in (Authenticate Customer)

When the flow reaches an **Authenticate Customer** block, the chat shows a sign-in card. The SDK
runs Amazon Cognito's hosted sign-in in an ephemeral web-authentication session and hands the
result to your backend, which completes it with Connect.

```swift
extension MyBackend: AuthenticationRelaying {
    func completeAuthentication(_ completion: AuthenticationCompletion) async throws {
        try await api.completeSignIn(completion)   // calls UpdateParticipantAuthentication
    }
}

let redirect = URL(string: "myapp-touchpoint://auth")!
let chat = try ConnectChatTransport.live(
    regionName: "us-west-2",
    authentication: ChatAuthentication(redirectURI: redirect, relay: backend))
```

**Connect setup**

- A Cognito user pool must be **associated with the instance** (console: Applications → Customer
  authentication, or `aws connect create-integration-association --integration-type
  COGNITO_USER_POOL`).
- The pool needs a domain for its hosted sign-in page and a public app client (no secret) with
  the authorization-code grant, the `openid` scope, and your redirect URI as its callback URL.
- In the block, choose the pool, the client and a Customer Profiles template (Store by default,
  `ObjectTypeName: Cognito-attributes` in flow JSON). Set a timeout, and branch on Success, Opted
  out, Timeout and Error.
- Your backend passes `state` and either `code` or `error` (with `errorDescription`) from
  `AuthenticationCompletion` to `UpdateParticipantAuthentication`.
- The customer has 60 seconds to tap the sign-in card before it expires.
- For the redirect URI, use a custom URL scheme, or an `https` universal link on iOS 17.4 or
  later (the app must own the domain). The
  [security guide](docs/SECURITY-GUIDE.md#sign-in-connects-authenticate-customer) has the details.

### 5. Guides (Connect Views)

A **Show view** block sends a guide card. If you pass your instance URL, the card opens the view
in a sheet and the customer's answer goes back to the flow.

```swift
TouchpointChatView(session: session,
                   views: try ConnectViewRendering(instanceURL: "https://your-instance.my.connect.aws"))
```

- The URL must be your instance's `https` access URL, on `*.my.connect.aws` or `*.awsapps.com`.
  Without `views:` the card shows but doesn't open.
- AWS-managed views (`arn:aws:connect:<region>:aws:view/form:1`, for example) need no
  `CreateView`. Branch the flow on the action names the view returns (`Next`, `Cancel`), plus a
  timeout.

### 6. Attachments

The paperclip appears while a human agent is on the contact. Files the agent sends open in Quick
Look.

- The instance needs **attachments storage** (an S3 bucket in its data storage settings).
  Without it, Connect refuses the upload and the agent workspace has no paperclip either.
- Files are limited to 8 MB and to JPEG, PNG, MP4, MOV and PDF: the web SDK's list, less WebP and
  AVI, which Connect's chat SDK refuses.

### 7. New-message notifications

The SDK posts no notifications and has no remote push. It reports each new message from the
other side, and your app decides what to do:

```swift
session.onIncomingMessages = { incoming in
    guard UIApplication.shared.applicationState != .active else { return }
    let content = UNMutableNotificationContent()
    content.title = "Support replied"   // generic text: the body shows on a locked phone
    content.userInfo = ["contactID": incoming.contactID]
    UNUserNotificationCenter.current().add(
        UNNotificationRequest(identifier: incoming.contactID, content: content, trigger: nil))
}
```

When the customer taps a notification after a relaunch, call `session.resume(contactID:)` rather
than starting a new contact. Messages that arrive while the app is suspended are reported when it
comes back, as one `.catchUp` call.

### 8. Voice

Voice places an outbound WebRTC call into your instance and runs it through CallKit.

```swift
import SwiftUI
import TouchpointCore
import TouchpointVoice

let voice = VoiceTransport()
let voiceSession = TouchpointSession(broker: broker, store: store, transports: [.voice: voice])
let call = TouchpointVoiceCall(session: voiceSession, transport: voice, displayName: "Example Bank",
                               permissionPolicy: PermissionPolicy(mayRequest: [.microphone]))
try await call.start()

// Full screen, with a Minimise that keeps the call going…
TouchpointVoiceView(call: call, onClose: { showCall = false }, onMinimise: { showCall = false })
// …and the floating rail for a minimised call.
TouchpointVoiceMiniRail(call: call)
```

**App setup**

- Add `NSMicrophoneUsageDescription` to Info.plist. The SDK asks for the microphone only if
  `permissionPolicy` allows it. Otherwise, ask for it yourself first.
- Add `UIBackgroundModes` with **both** `audio` and `voip`. `audio` keeps the call alive in the
  background, and `voip` lets CallKit start an outbound call. Without `voip`, `start()` fails
  with "CallKit refused the start request". You don't need PushKit, because the SDK places calls
  and never receives them.

**Connect setup**

- The backend calls `StartWebRTCContact` with a voice contact flow. The instance's Region must
  offer in-app WebRTC calling (and Agentic CX Designer, if the assistant answers).
- To have the assistant answer, use the same Agentic CX flow block as chat. Its speech recognition
  engine defaults to Amazon Connect agentic voice.
- For a human agent to take the call, the queue's routing profile must take voice as well as
  chat.
- `session.contactID` isn't set when `start()` returns, because CallKit starts the call later.
  Read it from `onStateChange` once the call reaches `.connected`.
- Your backend's `startVoiceContact` receives the call's `displayName` (your contact centre's name,
  as CallKit shows it) and no attributes. Identify the customer from your own authentication.

### 9. Screen share

The customer can share this app's screen (not the whole device) with the agent during a call.

```swift
let call = TouchpointVoiceCall(session: voiceSession, transport: voice, displayName: "Example Bank",
                               allowsScreenShare: true)

BalanceView().touchpointScreenShareRedacted()   // blacked out of every shared frame
PINEntryView().touchpointScreenShareSecure()    // blanks the whole frame while on screen
```

- With `allowsScreenShare`, `VoiceContactRequest.screenShare` is `true`. Your backend must then
  pass `AllowedCapabilities: {Customer: {ScreenShare: "SEND"}}` to `StartWebRTCContact`.
- The agent needs the **Video calls – Access** permission (`VideoContact.Access`) in a security
  profile, and starts the session from the agent workspace. `TouchpointVoiceMiniRail` then offers
  the customer the share control. The full-screen `TouchpointVoiceView` has none, so show the rail
  during a call, or build your own control from `call.screenShare`, `call.startScreenShare()` and
  `call.stopScreenShare()`.
- Sharing uses ReplayKit. iOS shows its own consent prompt and allows one capture at a time, so
  starting a share stops a Control Center screen recording.
- The share stops when the app goes to the background or the call ends.

### 10. Live Sync

Live Sync lets the assistant act on your app during a chat or call: open a screen, filter a list,
fill a form. Each screen declares the actions available while it is visible. The SDK advertises
the visible set and runs an action's handler when the assistant invokes it.

```swift
import SwiftUI
import TouchpointCore
import TouchpointLiveSync

struct TransactionFilter: TouchpointActionPayload {
    var amount: Double?
    var date: String?
    static let schema: JSONValue = [
        "type": "object", "additionalProperties": false,
        "properties": ["amount": ["type": "number"], "date": ["type": "string", "format": "date"]],
    ]
}

TransactionsScreen(model: model)
    .touchpointAction("filter_transactions", description: "Filter the list by amount or date") {
        (filter: TransactionFilter) in model.apply(filter)
    }
    .touchpointScope("transactions")   // outside the actions it tags
```

Once the contact exists, bind a client to it and attach the declarations at the root:

```swift
let client = LiveSyncClient(
    configuration: LiveSyncConfiguration(region: "us-west-2", conversationId: contactID,
                                         channel: try LiveSyncChannel(locale: .current)),
    credentials: broker, session: chatOrVoiceSession)
let aggregator = TouchpointActionAggregator(client: client)
let consent = LiveSyncConsentController(
    client: client, store: ConsentStore(keychain: keychain, deploymentID: "support-assistant"),
    prompt: ConsentPrompt(dataDescription: "which screen you're on and what you can do there",
                          recipient: "Example Bank's assistant"))
await consent.load()

RootView()
    .touchpointLiveSync(aggregator)
    .touchpointActionConfirmation(client)   // for actions declared with confirmationRequired
    .liveSyncConsent(consent)               // asks once; no context is posted until the customer agrees
```

How it behaves:

- **Consent governs sharing.** No context is posted until the customer grants consent, so the
  assistant learns nothing about the screen. The receive-only socket opens when the client is created; to
  keep it closed until consent, pass `autoConnect: false` and call `connect()` after the grant.
  Revoking consent closes the socket, and granting it again doesn't reopen it, so call
  `connect()` after a re-grant as well. The decision is kept per deployment, not per user.
- **The caller drives the actions.** As on Touchpoint for the web, the assistant acts on what the
  customer asks for, by voice or text, through the actions the current screen declares. Consent is
  not a gate on those actions; keep the socket closed until the grant if none may run before it.
- **Agent present, assistant paused.** While a human agent or supervisor is on the contact, and
  after a reconnect until the transcript is reconciled, invocations are dropped, not queued. When
  the last person leaves, the assistant can act again, so handing back to it needs no code.
- **Payloads are checked on the device** against the schema you declared. The SDK supports a
  strict subset of JSON Schema and fails closed on anything else; the
  [security guide](docs/SECURITY-GUIDE.md#live-sync-actions) lists it. Still check business rules
  in the handler.
- **Declare only reversible actions.** Declare what the customer can undo, never a payment, a
  transfer or a submission. `confirmationRequired: true` adds a prompt to a reversible action (the
  guide lists what drops a held action); it doesn't make an irreversible one safe to declare.
- **Bind to the right contact.** For chat, bind after `startChat` returns. For voice, bind when
  the call reaches `.connected`. A client bound to an old contact stays connected and receives
  nothing. Pass the contact's `session:` too; without it there is no pause for a human agent and
  no teardown when the contact ends.
- **Keep each screen's context small.** Live Sync accepts up to 8 KB of context per update, so
  declare only the actions the screen needs, with short descriptions and schemas.
- **One client per contact.** If your view tree outlives contacts, use
  `TouchpointActionAggregator(confirmations:post:)`. Forward `confirmations` to the current
  client's `confirmationRequirements`, or gated actions run unconfirmed. Pass `report:` too, or
  failed posts and unrouted invocations go unreported. Set each client's `onAction` to the
  aggregator's `route(_:)` and its `onContextNeeded` to `readvertise()`, and call `readvertise()`
  after switching clients.

**Agentic CX Designer setup**

- The contact flow's Agentic CX flow block must point at the application that has the **Live Sync
  node**. Live Sync then follows the same contact.
- In that node, declare each action your app advertises as a custom action, with the same name
  and schema, and scope tags that match your `.touchpointScope` names. The assistant doesn't
  reliably use an action the node doesn't know.
- Your backend vends two values from the application's settings, under **Access**: the
  **deployment key** (the same value as the block's alias) and the **API key**. A Live Sync
  *script* key doesn't work here. The service refuses the context request with 403, so the
  assistant never learns what the screen can do.
- The keys don't expire on their own. Return `expiresAt` if you rotate them on a schedule. If you
  return `nil`, the SDK keeps them until the service refuses them or you call
  `rotateCredentials()`.
- The SDK builds the channel as `connect-<language>` from the locale you pass. If the application
  supports one language, pass that locale rather than `.current`.
- Unlike chat and voice, Live Sync needs no AWS credentials on the backend, only the two keys.

**When the assistant talks but the app doesn't move**, check in this order: the contact id the
client is bound to; whether the action is in the advertised set on the current screen (a scope
applied inside the action, or a screen that declares nothing); then `LiveSyncClient.onError`
(including `.contactMayBeStale`) and `diagnostics` (`rejectedInvocations`,
`suppressedInvocations`). In debug builds, `TouchpointLiveSyncOverlay(aggregator:client:)` shows
the connection and dispatch state, the advertised and pending actions, scopes and unrouted
invocations.

### Setup checklist

| Feature | Amazon Connect | Agentic CX Designer | Your backend | Your app |
| --- | --- | --- | --- | --- |
| Chat | Chat-enabled instance, inbound chat flow, queue, routing profile, agents | — | `StartChatContact` with the interactive content types | `ConnectChatTransport` |
| Assistant | Flow with the Agentic CX flow block | Deployed application and its alias | — | `.touchpointModality` for custom modalities |
| Sign-in | Cognito pool associated with the instance; Authenticate Customer block with Customer Profiles config | — | `UpdateParticipantAuthentication` | `ChatAuthentication`, redirect URI |
| Guides | Show view block | — | — | `ConnectViewRendering(instanceURL:)` |
| Attachments | Attachments storage (S3) | — | — | — |
| Voice | Voice contact flow; routing profile that takes voice; Region with WebRTC calling | — | `StartWebRTCContact`, `ClientToken` | Microphone description; `audio` + `voip` background modes |
| Screen share | Agent security profile with Video calls – Access | — | `AllowedCapabilities.Customer.ScreenShare = SEND` | `allowsScreenShare: true`; redaction |
| Live Sync | Flow whose Agentic CX flow block uses the Live Sync application | Live Sync node declaring the actions and scope tags; deployed build | Vends the deployment key and API key | `.touchpointAction`, consent, bind on contact |

## Developing

```sh
make hooks     # once per clone: pre-commit (lint + staged secret scan) and pre-push (make check)
make check     # version, build, test, lint, scan, dependency graph, privacy manifests, inherited declarations, string catalog, release symbols, gate self-tests, competing pins, app build
make check-clt # the same minus competing pins and the app build, for a CommandLineTools-only machine
make build-ios # all four products against a generic iOS device (needs full Xcode)
```

`make check` needs no device and no credentials. It needs network access for package resolution,
and Python 3. It has one limit: the Connect chat SDK and Chime are linked on iOS only, so on macOS
`swift test` exercises `TouchpointChat` and `TouchpointVoice` against Core alone. `make build-ios`
is what proves the real SDK link. The gates `make check` runs, and the requirement each one
enforces:

| Gate | Requirement |
| --- | --- |
| `Scripts/lint.sh` | No `fatalError`, `preconditionFailure`, `precondition`, `assert`, `assertionFailure`, `exit`, or force-unwrap in library code; no literal font sizes or bare-number dimensions in view code (use the scaled metrics) |
| `Scripts/scan-secrets.sh` | No credential, internal hostname, account identifier, internal link, or pre-publication vendor/service naming in committed source. Scans staged blobs (pre-commit) and untracked files (whole-tree) |
| `Scripts/check-build-graph.sh` | `TouchpointChat` does not transitively link Chime; Core and LiveSync link neither external SDK. Transitive across all resolved packages |
| `Scripts/check-privacy-manifests.sh` | Every target ships a valid `PrivacyInfo.xcprivacy` |
| `Scripts/check-inherited-declarations.sh` | The privacy declarations every linked dependency merges into a host are a reviewed baseline (`Scripts/inherited-declarations.json`); a dependency bump that changes them fails until re-reviewed |
| `Scripts/check-string-catalog.sh` | User-facing strings go through the String Catalog |
| `Scripts/check-release-symbols.sh` | A release build of `TouchpointCore` contains no `DevelopmentBackend` symbol |
| `Scripts/test-scripts.sh` | Each gate still catches what it should, run against fixtures in `Tests/Fixtures` |
| `Scripts/check-competing-pins.sh` | An integrator's own pin of the Connect, AWS or Chime SDK either resolves at or above the floor or fails naming the package and both versions |
| `Scripts/check-version.sh` | `Touchpoint.version` is SemVer and `CHANGELOG.md` has a section for it; a release tag must equal it |

GitHub Actions runs `make check`, `make build-ios` and
CodeQL on every pull request, and lists its public API changes. A release tag is checked against
`Touchpoint.version`, `CHANGELOG.md` and the previous release's public API
(`Scripts/check-api-breaks.sh`). How to contribute,
and how a release is cut: [CONTRIBUTING.md](CONTRIBUTING.md). What changed in each release:
[CHANGELOG.md](CHANGELOG.md).

## Security

To report a potential security issue, use the AWS
[vulnerability reporting page](https://aws.amazon.com/security/vulnerability-reporting/); please do
**not** create a public GitHub issue. What the SDK protects, and what your app and backend must do, is
in the [security guide](docs/SECURITY-GUIDE.md).

## Licence

MIT. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
