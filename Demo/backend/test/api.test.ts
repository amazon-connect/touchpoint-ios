import assert from 'node:assert/strict';
import { before, test } from 'node:test';
import type { APIGatewayProxyEventV2, APIGatewayProxyStructuredResultV2 } from 'aws-lambda';

// Validation runs before any AWS call, so these need no credentials.
let handler: (e: APIGatewayProxyEventV2) => Promise<unknown>;
before(async () => {
  Object.assign(process.env, {
    INSTANCE_ID: '00000000-0000-0000-0000-000000000000',
    CHAT_FLOW_ID: 'chat',
    VOICE_FLOW_ID: 'voice',
    SECRET_ID: 'secret',
    DEPLOYMENT_KEY: 'alias',
    SECRET_PLACEHOLDER: 'REPLACE_ME',
    AWS_REGION: 'us-east-1',
  });
  ({ handler } = await import('../lambda/demo-api/index'));
});

const call = async (routeKey: string, body: unknown) =>
  (await handler({ routeKey, body: typeof body === 'string' ? body : JSON.stringify(body) } as APIGatewayProxyEventV2)) as APIGatewayProxyStructuredResultV2;

test('unknown route is a 404', async () => assert.equal((await call('GET /', {})).statusCode, 404));
test('malformed JSON is a 400', async () => assert.equal((await call('POST /chat/start', '{nope')).statusCode, 400));
test('a JSON array body is a 400', async () => assert.equal((await call('POST /chat/start', [])).statusCode, 400));
test('displayName is required', async () => assert.equal((await call('POST /chat/start', { attributes: {} })).statusCode, 400));
test('an unknown flow is refused, so a client cannot pick a flow id', async () =>
  assert.equal((await call('POST /chat/start', { displayName: 'Jordan', flow: 'arn:aws:connect:x' })).statusCode, 400));
test('attributes must be strings', async () =>
  assert.equal((await call('POST /chat/start', { displayName: 'Jordan', attributes: { screen: 1 } })).statusCode, 400));
test('too many attributes are refused', async () => {
  const attributes = Object.fromEntries(Array.from({ length: 21 }, (_, i) => [`k${i}`, 'v']));
  assert.equal((await call('POST /chat/start', { displayName: 'Jordan', attributes })).statusCode, 400);
});
test('a malformed clientToken is refused', async () =>
  assert.equal((await call('POST /voice/start', { displayName: 'Jordan', clientToken: 'x' })).statusCode, 400));
test('screenShare must be a boolean', async () =>
  assert.equal((await call('POST /voice/start', { displayName: 'Jordan', screenShare: 'yes' })).statusCode, 400));

test('the flow names the demo apps send are accepted (validation passes before Connect is called)', async () => {
  for (const flow of ['default', 'livesync', 'showcase']) {
    const r = await call('POST /chat/start', { displayName: 'Jordan Rivera', flow, attributes: { screen: 'accounts', app: 'AcmeBank', platform: 'ios' } });
    assert.notEqual(r.statusCode, 400, `flow ${flow} was refused`);
  }
});
