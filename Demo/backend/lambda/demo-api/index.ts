// The demo API: the Touchpoint SDK's TouchpointBackend, over HTTP. Every route requires AWS_IAM
// (SigV4) at API Gateway; this function never sees an unsigned request.
//
//   POST /chat/start           {"displayName": str, "attributes": {str: str}, "flow"?: "default" | "livesync" | "showcase"}
//                           -> {"contactId", "participantId", "participantToken", "expiresAt": null}
//   POST /voice/start          {"displayName": str, "attributes": {str: str}, "clientToken"?: str, "screenShare"?: bool}
//                           -> the above plus {"meeting", "attendee"} (StartWebRTCContact's ConnectionData)
//   POST /livesync/credentials {} -> {"deploymentKey", "apiKey", "expiresAt": null}
//
// The Amazon Connect instance and flow ids live here, never in the app. Attributes are forwarded as
// given: they must not carry secrets. Errors return the error class only; nothing a caller sent, and
// no token, is ever logged.
import {
  ConnectClient,
  LimitExceededException,
  StartChatContactCommand,
  StartWebRTCContactCommand,
} from '@aws-sdk/client-connect';
import { GetSecretValueCommand, SecretsManagerClient } from '@aws-sdk/client-secrets-manager';
import type { APIGatewayProxyEventV2, APIGatewayProxyResultV2 } from 'aws-lambda';
import { randomUUID } from 'node:crypto';

const connect = new ConnectClient({});
const secrets = new SecretsManagerClient({});

const env = (name: string) => {
  const v = process.env[name];
  if (!v) throw new Error(`${name} is not set`);
  return v;
};
const INSTANCE_ID = env('INSTANCE_ID');
const CHAT_FLOW_ID = env('CHAT_FLOW_ID');
const VOICE_FLOW_ID = env('VOICE_FLOW_ID');
const SECRET_ID = env('SECRET_ID');
const DEPLOYMENT_KEY = env('DEPLOYMENT_KEY');
const PLACEHOLDER = env('SECRET_PLACEHOLDER');

// An allowlist: the client names a flow, the backend owns the id. Every name starts the Live Sync
// chat flow: the Acme Bank demo asks for "showcase" once Live Sync keys are set, "default" before.
const FLOWS: Record<string, string> = { default: CHAT_FLOW_ID, livesync: CHAT_FLOW_ID, showcase: CHAT_FLOW_ID };

const NAME_RE = /^[\p{L}\p{N}_ .,'-]{1,256}$/u;
const TOKEN_RE = /^[A-Za-z0-9_-]{8,128}$/;
const MAX_ATTRS = 20;

type Body = Record<string, unknown>;
const reply = (statusCode: number, body: unknown): APIGatewayProxyResultV2 => ({
  statusCode,
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify(body),
});

function validate(body: Body): { name: string; attrs: Record<string, string> } | APIGatewayProxyResultV2 {
  const name = body.displayName;
  const attrs = (body.attributes ?? {}) as unknown;
  if (typeof name !== 'string' || !NAME_RE.test(name)) {
    return reply(400, { error: "displayName is required: 1-256 letters, digits, spaces, . , ' -" });
  }
  if (
    typeof attrs !== 'object' || attrs === null || Array.isArray(attrs) ||
    Object.keys(attrs).length > MAX_ATTRS ||
    !Object.entries(attrs).every(([k, v]) => typeof v === 'string' && k.length <= 64 && v.length <= 1024)
  ) {
    return reply(400, { error: 'attributes must be a small map of short strings' });
  }
  return { name, attrs: { channel: 'touchpoint-demo', ...(attrs as Record<string, string>) } };
}

const isReply = (v: unknown): v is APIGatewayProxyResultV2 => typeof v === 'object' && v !== null && 'statusCode' in v;

function failure(op: string, err: unknown): APIGatewayProxyResultV2 {
  if (err instanceof LimitExceededException) return reply(429, { error: 'contact limit reached; try again shortly' });
  // CloudWatch gets the class name only: a service error message can echo request values.
  const name = (err as Error)?.name ?? 'Error';
  console.log(JSON.stringify({ msg: `${op} failed`, error: name }));
  return reply(502, { error: name });
}

async function startChat(body: Body) {
  const v = validate(body);
  if (isReply(v)) return v;
  const flow = body.flow ?? 'default';
  if (typeof flow !== 'string' || !FLOWS[flow]) return reply(400, { error: `unknown flow; one of ${Object.keys(FLOWS).join(', ')}` });
  try {
    const r = await connect.send(
      new StartChatContactCommand({
        InstanceId: INSTANCE_ID,
        ContactFlowId: FLOWS[flow],
        ParticipantDetails: { DisplayName: v.name },
        Attributes: v.attrs,
        SupportedMessagingContentTypes: [
          'text/plain',
          'text/markdown',
          'application/json',
          'application/vnd.amazonaws.connect.message.interactive',
          'application/vnd.amazonaws.connect.message.interactive.response',
        ],
      }),
    );
    // StartChatContact returns no expiry: the token lives as long as the contact.
    return reply(200, { contactId: r.ContactId, participantId: r.ParticipantId, participantToken: r.ParticipantToken, expiresAt: null });
  } catch (err) {
    return failure('StartChatContact', err);
  }
}

async function startVoice(body: Body) {
  const v = validate(body);
  if (isReply(v)) return v;
  // Idempotency: a client that retries after a gateway timeout must not start a second call.
  const clientToken = body.clientToken;
  if (clientToken !== undefined && !(typeof clientToken === 'string' && TOKEN_RE.test(clientToken))) {
    return reply(400, { error: 'clientToken must be 8-128 of [A-Za-z0-9_-]' });
  }
  const screenShare = body.screenShare ?? false;
  if (typeof screenShare !== 'boolean') return reply(400, { error: 'screenShare must be a boolean' });
  try {
    const r = await connect.send(
      new StartWebRTCContactCommand({
        InstanceId: INSTANCE_ID,
        ContactFlowId: VOICE_FLOW_ID,
        ParticipantDetails: { DisplayName: v.name },
        Attributes: v.attrs,
        ClientToken: (clientToken as string | undefined) ?? randomUUID(),
        // Screen sharing only when asked: the customer may send their app's screen, and the agent gets
        // video capability too, which the agent workspace needs before it shows the call's video area
        // (where a shared screen appears). The customer's camera is never requested.
        ...(screenShare
          ? { AllowedCapabilities: { Customer: { ScreenShare: 'SEND' }, Agent: { Video: 'SEND', ScreenShare: 'SEND' } } }
          : {}),
      }),
    );
    return reply(200, {
      contactId: r.ContactId,
      participantId: r.ParticipantId,
      participantToken: r.ParticipantToken,
      expiresAt: null,
      meeting: r.ConnectionData?.Meeting,
      attendee: r.ConnectionData?.Attendee,
    });
  } catch (err) {
    return failure('StartWebRTCContact', err);
  }
}

// Live Sync's socket takes the deployment alias (the deployment key) and the application API key.
// The app gets them here, from a signed-in session, instead of carrying them in the binary.
async function liveSyncCredentials() {
  try {
    const raw = (await secrets.send(new GetSecretValueCommand({ SecretId: SECRET_ID }))).SecretString;
    const apiKey = (JSON.parse(raw ?? '{}') as Record<string, string>).liveSyncApiKey;
    if (!apiKey || apiKey === PLACEHOLDER) return reply(503, { error: 'Live Sync is not configured: liveSyncApiKey is unset in the secret' });
    return reply(200, { deploymentKey: DEPLOYMENT_KEY, apiKey, expiresAt: null });
  } catch (err) {
    return failure('GetSecretValue', err);
  }
}

export const handler = async (event: APIGatewayProxyEventV2): Promise<APIGatewayProxyResultV2> => {
  let body: Body;
  try {
    body = JSON.parse(event.body ?? '{}') as Body;
    if (typeof body !== 'object' || body === null || Array.isArray(body)) return reply(400, { error: 'body must be a JSON object' });
  } catch {
    return reply(400, { error: 'malformed JSON' });
  }
  switch (event.routeKey) {
    case 'POST /chat/start':
      return startChat(body);
    case 'POST /voice/start':
      return startVoice(body);
    case 'POST /livesync/credentials':
      return liveSyncCredentials();
    default:
      return reply(404, { error: 'unknown route' });
  }
};
