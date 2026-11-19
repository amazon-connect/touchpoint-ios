#!/usr/bin/env node
import { App, Tags } from 'aws-cdk-lib';
import { AgentStack } from '../lib/agent-stack';
import { BaseStack } from '../lib/base-stack';
import { AGENT_STACK_NAME, BASE_STACK_NAME, TAGS } from '../lib/config';
import { applySecurityChecks } from '../lib/security';

const app = new App();

// Your existing Amazon Connect instance: INSTANCE_ID in .env (the npm scripts pass it on).
// A free Amazon Connect sandbox on AWS Builder Center works. Agentic CX Designer must be available
// in the instance's Region.
const instanceId = (app.node.tryGetContext('instanceId') as string | undefined) ?? process.env.INSTANCE_ID;
if (!instanceId || !/^[0-9a-f-]{36}$/.test(instanceId)) {
  throw new Error('Set INSTANCE_ID in .env (your Amazon Connect instance id), then use npm run deploy:base / npm run deploy.');
}

const env = { account: process.env.CDK_DEFAULT_ACCOUNT, region: process.env.AWS_REGION ?? process.env.CDK_DEFAULT_REGION };

const base = new BaseStack(app, BASE_STACK_NAME, {
  env,
  description: 'Touchpoint SDK demo, step 1: the demo user pool and the Agentic CX Designer key secret',
});

const agent = new AgentStack(app, AGENT_STACK_NAME, {
  env,
  description: 'Touchpoint SDK demo, step 3: the dispute AI agent, contact flows, and the demo API',
  instanceId,
  userPool: base.userPool,
  userPoolClient: base.userPoolClient,
  secret: base.secret,
});

for (const [key, value] of Object.entries(TAGS)) Tags.of(app).add(key, value);

// cdk-nag (AWS Solutions) on every synth; lib/security.ts lists what the demo accepts and why.
applySecurityChecks(app, base, agent);
