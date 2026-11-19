# Acme Bank — Touchpoint SDK demo

A fictional bank app that integrates the Touchpoint SDK the way a customer would: by package
dependency, through the public API only. Everything in it is synthetic. It is not part of the
published package.

```sh
make demo-project                 # generate AcmeBank.xcodeproj (fetches XcodeGen into .build/tools once)
open Demo/AcmeBank/AcmeBank.xcodeproj
```

## Modes

**Offline** (the default) talks to a scripted agent and needs nothing provisioned.

**Live** (debug builds; Settings → Support mode) reaches your own Amazon Connect instance, where an AI
agent built in Agentic CX Designer drives the app through Live Sync to help the customer dispute a card
charge, by chat or by an in-app call, and can hand the customer to a person who sees their screen.

1. Deploy the backend in [`Demo/backend`](../backend/README.md) (AWS CDK) into your account.
2. In `Demo/backend`, run `npm run app-config` and save the iOS part as
   `Demo/AcmeBank/Resources/LiveConfig.plist` (gitignored; see `LiveConfig.example.plist`). It holds
   identifiers only — the API endpoint, the Region, the Cognito pool and client ids, the Connect
   instance URL — never a key or a credential.
3. `make demo-project`, build and run, and sign in as the demo user you created.

The app signs the user in to the backend's Cognito user pool and gets temporary credentials that can
call the demo API and nothing else; it gets the Live Sync keys from the backend too. Any `ACME_*`
variable set when you run `make demo-project` overrides the plist for runs from Xcode.

> A production app never carries AWS credentials: it authenticates its own users, and its own backend
> starts the contact. The demo's shape lets a sample reach a real instance without an app server.

## Live Sync

The AI agent can act only through the actions the current screen advertises (`touchpointAction` /
`touchpointScope`); their schemas are in `Resources/ActionContract`. Opening an account, filtering
and selecting a transaction, opening the dispute form and filling it in are actions. **Submitting is
not**: the customer taps Submit, and a test fails if a submit action is added. In a debug build the
Live Sync overlay shows each action as it arrives.

## Design review

Settings → Design review has the header brand, avatar and slow-motion switches that a screen
recording of the SDK's components needs.

## Notifications

The SDK posts none: it reports each reply through `TouchpointSession.onIncomingMessages`, and this
app decides.
- Its policy (`SupportCoordinator.handleIncoming`): one generic local notification, "Acme Bank / You
  have a new message from support", unless the conversation is on screen in the foreground. Never
  the message text.
- A tap opens the dock on that conversation. If the app was relaunched since the notification was
  posted, it resumes the conversation from the store instead of starting a new one.
- The permission prompt comes when the first chat opens, never at launch. UI tests launch without
  it; only the prompt's own test opts in (`-promptNotifications`), and it skips on a simulator that
  has already answered.
- Only a running app is notified. Replies that arrive while the app is suspended show up when it
  returns (one catch-up notification unless the chat is on screen). There is no remote push.

## Tests

`AcmeBankTests` covers the fixture's data, the dispute flow and the notification policy;
`AcmeBankUITests` signs in, opens Support, sends a message, and runs `performAccessibilityAudit()`.
`make check` builds the app and both test bundles (`Scripts/check-demo-builds.sh`).
