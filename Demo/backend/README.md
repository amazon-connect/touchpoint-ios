# Acme Bank demo backend (AWS CDK)

The backend for **Acme Bank**, the demo app in the Amazon Connect Customer Touchpoint SDKs for iOS
([`Demo/AcmeBank`](../AcmeBank/README.md)) and
[Android](https://github.com/amazon-connect/touchpoint-android). Deploy it into your own AWS account and
the demo's **live mode** talks to your Amazon Connect instance, where an AI agent built in Agentic CX
Designer drives the app through **Live Sync** to help a customer dispute a card charge — by chat or by an
in-app call — and can hand the customer to a person who sees their screen.

## Quick start

```sh
cd Demo/backend
cp .env.example .env              # set INSTANCE_ID and AWS_REGION
npm ci
npm run doctor                    # checks your setup and says what to do next

npm run deploy:base               # user pool + key secret            (~2 min)
npm run create-user               # a demo user, with a password you choose

# Console: in Agentic CX Designer, create an application named "acme-dispute" and a
#          programmatic user with an API key (step 2 below)
npm run set-keys

npm run deploy                    # AI agent, contact flows, API      (~5 min)

# Console: copy acme-dispute > Settings > Access > API key (step 4 below)
npm run set-livesync-key
npm run verify                    # the API refuses anonymous callers

npm run app-config                # settings for the iOS or Android demo
```

`npm run doctor` is safe to run at any point: it changes nothing and tells you the next step.

## What it deploys

| Stack | Resources |
|---|---|
| `TouchpointDemo` | Amazon Cognito user pool for demo users (no self sign-up); a Secrets Manager secret for the Agentic CX Designer keys |
| `TouchpointDemoAgent` | The dispute AI agent, deployed with the [Agentic CX Designer SDK](https://www.npmjs.com/package/amazon-connect-acxd-sdk) from a CloudFormation custom resource; chat and voice contact flows (Amazon Connect agentic voice); a queue, routing profile, security profile and agent user for hand-offs and screen sharing; the demo API (Amazon API Gateway HTTP API + AWS Lambda); a Cognito identity pool |

The demo API:

| Route | What it does |
|---|---|
| `POST /chat/start` | `StartChatContact` on the Live Sync chat flow |
| `POST /voice/start` | `StartWebRTCContact` (in-app call) on the Live Sync voice flow, with screen sharing when asked |
| `POST /livesync/credentials` | The Live Sync deployment key and application API key, so the app never carries them |

**Every route requires AWS_IAM (SigV4).** A demo user signs in to the user pool, and the identity pool
trades the ID token for temporary credentials whose role can call this API and nothing else. The Lambda
function's own role can start chat and in-app calls on your one instance and these two flows only.

> A production app does not give AWS credentials to the device: it authenticates its own users, and its
> own backend starts the contact. This shape lets a sample reach a real instance without an app server.

## Prerequisites

- An Amazon Connect instance in a Region where Agentic CX Designer and Live Sync are available, with
  inbound calls enabled and an **Agentic CX Designer workspace** (created the first time you open Agentic
  CX Designer from the instance's admin website). A free Amazon Connect sandbox on AWS Builder Center works.
- Node.js 22 or later, and AWS credentials for the account (your default credentials, or `AWS_PROFILE`
  in `.env`).
- The account bootstrapped for AWS CDK in that Region (`npx cdk bootstrap`; `npm run doctor` checks).

## Step by step

### 1. Deploy the base stack and create a demo user

```sh
npm run deploy:base
npm run create-user        # prompts for a username (default jordan) and a password, without echo
```

### 2. Create the Agentic CX Designer keys (console)

These can only be created in the console.

1. In the Amazon Connect admin website, open **Agentic CX Designer** and your workspace.
2. Create an application named **`acme-dispute`**. Leave its settings; the deploy configures it.
3. Under **Workspace > Users > API Access**, create a programmatic user with the **Workspace
   administrator** role on this workspace only, then **Generate API key** (it is shown once).
4. Run `npm run set-keys` and paste the key and the workspace id (from the browser URL:
   `…/acxd/w/<workspace-id>/applications`). Nothing is echoed or written to disk.

### 3. Deploy the AI agent, flows and API

```sh
npm run deploy
```

The custom resource creates the context variables and the dispute flow, builds and deploys
`acme-dispute`, and returns its deployment alias; the stack then creates the contact flows, the hand-off
routing and the API. If the keys are missing, the deploy stops and says so.

### 4. Add the Live Sync key

The Live Sync socket uses the application's own API key, which no API returns. In Agentic CX Designer
open **Applications > acme-dispute > Settings > Access**, copy the API key, then:

```sh
npm run set-livesync-key
npm run verify
```

`verify` sends an unsigned request and one with a forged signature and requires both to be refused
before it sends one signed with your credentials. If either succeeds it prints `EXPOSED` and fails.

### 5. Connect a demo app

```sh
npm run app-config
```

prints the iOS `LiveConfig.plist` and the Android `live.properties`. For iOS, save the first as
`Demo/AcmeBank/Resources/LiveConfig.plist` (gitignored), then from the repository root run
`make demo-project`, open `Demo/AcmeBank/AcmeBank.xcodeproj`, build and run, and sign in as your demo
user. The app starts in live mode and gets the Live Sync keys from the backend.

## Hand-off and screen sharing (optional)

When the customer asks for a person, the AI agent escalates and the contact flow transfers the chat or
call to the `touchpoint-demo-support` queue. On an in-app call the agent can then see the customer's app.
Screen sharing needs a physical phone (the iOS Simulator has no ReplayKit or CallKit).

```sh
npm run agent-password     # copies the agent's initial password to the clipboard
```

1. Sign in to `https://<instance-alias>.my.connect.aws/agent-app-v2` as `touchpoint-agent`, set a new
   password, allow the microphone, and go **Available**.
2. In the demo on a phone: Support > **Call us**, then ask for a person.
3. Accept the call, then start screen sharing; on the phone, tap the share control on the call bar and
   accept iOS's prompt. Views marked `touchpointScreenShareRedacted()` are blacked out.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Deploy fails: "placeholder values" | Run `npm run set-keys` first |
| Deploy fails: "No application named acme-dispute" | Create it in Agentic CX Designer with exactly that name |
| Deploy fails: "cannot open workspace" | The key was revoked, the workspace id is wrong, or the programmatic user is not Workspace administrator |
| App: "The demo backend refused the request (HTTP 400)" | The app asked for a flow name the API does not allow; the API accepts `default`, `livesync` and `showcase` |
| App: "Sign-in is unavailable right now (ResourceNotFoundException)" | The app is using the wrong Region or pool ids. Regenerate the settings with `npm run app-config`; on iOS a value in the Xcode scheme's environment overrides `LiveConfig.plist` |
| App: "Live Sync is not configured" | Run `npm run set-livesync-key` |
| Live Sync connected but the screen does not move | The AI agent can only call actions the current screen advertises; the debug overlay in the demo shows which |
| An action marked `confirmationRequired` never arrives | Known issue: such actions are advertised but not delivered. The demo does not require confirmation to open the dispute screen; Submit is always the customer's tap |
| A chat started by your own test client never gets a greeting | The contact flow starts only once the customer's participant websocket is open; `CreateParticipantConnection` needs both `WEBSOCKET` and `CONNECTION_CREDENTIALS` |
| The agent workspace shows no video area on a screen-share call | The call must give the agent `Video: SEND` as well as the customer `ScreenShare: SEND`; this API does |
| Anything else | Turn on flow logs (`npm run doctor` checks) and look in `/aws/connect/<instance-alias>`; the API's access logs are in the `…DemoApiAccessLogs…` log group |

## Costs

You pay for what you use: Amazon Connect chat and in-app calling, Agentic CX Designer, API Gateway,
Lambda, Cognito and Secrets Manager. Idle, the backend costs very little (two secrets and the always-on
pieces of your Connect instance). See the pricing pages for your Region.

## Clean up

```sh
npm run destroy                       # removes both stacks
npm run destroy -- --delete-acxd-app  # also deletes the acme-dispute application and its flow
```

Then delete the programmatic user in Agentic CX Designer (**Workspace > Users > API Access**).

## Development

The AI agent's actions are declared from the app's own schemas in
`Demo/AcmeBank/Resources/ActionContract`, so a change to an action there changes the agent too.


```sh
npm test         # action contract, flow, routing and API validation tests (CI runs these too)
npm run build    # type-check
npm run synth    # CloudFormation templates
```
