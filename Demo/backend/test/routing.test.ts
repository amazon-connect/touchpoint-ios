import assert from 'node:assert/strict';
import { test } from 'node:test';
import { App } from 'aws-cdk-lib';
import { Template } from 'aws-cdk-lib/assertions';
import { AgentStack } from '../lib/agent-stack';
import { BaseStack } from '../lib/base-stack';

const app = new App();
const base = new BaseStack(app, 'Base', {});
const agent = new AgentStack(app, 'Agent', {
  instanceId: '00000000-0000-0000-0000-000000000000',
  userPool: base.userPool, userPoolClient: base.userPoolClient, secret: base.secret,
});
const t = Template.fromStack(agent);

test('the agent can view a shared screen and nothing more', () => {
  t.hasResourceProperties('AWS::Connect::SecurityProfile', { Permissions: ['BasicAgentAccess', 'VideoContact.Access'] });
});

test("the agent's password is a Secrets Manager reference, never a value", () => {
  const users = Object.values(t.findResources('AWS::Connect::User')) as any[];
  assert.equal(users.length, 1);
  assert.match(JSON.stringify(users[0].Properties.Password), /resolve:secretsmanager/);
});

test('both contact flows transfer an escalation to the support queue', () => {
  const flows = Object.values(t.findResources('AWS::Connect::ContactFlow')) as any[];
  assert.equal(flows.length, 2);
  for (const f of flows) {
    const content = JSON.stringify(f.Properties.Content);
    assert.match(content, /TransferContactToQueue/);
    assert.match(content, /UpdateContactTargetQueue/);
  }
});

test('every API route requires AWS_IAM', () => {
  const routes = Object.values(t.findResources('AWS::ApiGatewayV2::Route')) as any[];
  assert.equal(routes.length, 3);
  for (const r of routes) assert.equal(r.Properties.AuthorizationType, 'AWS_IAM');
});

test('both flows set the agentic voice; only the voice flow plays audio filler', () => {
  const flows = Object.values(t.findResources('AWS::Connect::ContactFlow')) as any[];
  for (const f of flows) {
    const content = JSON.stringify(f.Properties.Content);
    assert.match(content, /UpdateContactTextToSpeechVoice/);
    assert.match(content, /connect:agentic/);
  }
  const filler = flows.map((f) => /TYPING_QUIET_QWERTY/.test(JSON.stringify(f.Properties.Content)));
  assert.deepEqual(filler.sort(), [false, true]);
});
