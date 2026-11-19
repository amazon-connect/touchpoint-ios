import { Stack, aws_connect as connect } from 'aws-cdk-lib';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { Construct } from 'constructs';
import { BANK_NAME, FLOWS, VOICE } from '../config';
import { AcxdApp } from './acxd-app';

export interface ContactFlowsProps {
  readonly instanceId: string;
  readonly acxd: AcxdApp;
  /** Where the Escalation branch sends a contact the AI agent hands to a person. */
  readonly queueArn: string;
}

/**
 * The chat and voice contact flows. Both hand the contact to the dispute AI agent and map the
 * attributes the app sent (`screen`, `transactionId`) to the agent's context variables. When the AI
 * agent escalates, the contact goes to the support queue, where an agent can take it (and, on a call,
 * view the customer's shared screen). One template,
 * lib/flows/livesync.json, with {{Placeholders}} filled in here.
 */
export class ContactFlows extends Construct {
  readonly chat: connect.CfnContactFlow;
  readonly voice: connect.CfnContactFlow;
  readonly instanceArn: string;

  constructor(scope: Construct, id: string, props: ContactFlowsProps) {
    super(scope, id);
    this.instanceArn = Stack.of(this).formatArn({ service: 'connect', resource: 'instance', resourceName: props.instanceId });

    const flow = (logicalId: string, name: string, channel: 'chat' | 'voice') =>
      new connect.CfnContactFlow(this, logicalId, {
        instanceArn: this.instanceArn,
        name,
        description: `Touchpoint demo (${channel}): hands the contact to the Agentic CX Designer dispute agent`,
        type: 'CONTACT_FLOW',
        state: 'ACTIVE',
        content: render({
          AcxdWorkspaceId: props.acxd.workspaceId,
          AcxdApplicationId: props.acxd.applicationId,
          AcxdAlias: props.acxd.deploymentAlias,
          Channel: channel,
          BankName: BANK_NAME,
          QueueArn: props.queueArn,
          VoiceName: VOICE.name,
          VoiceEngine: VOICE.engine,
        }, {
          // Quiet typing while the AI agent works, on calls only (a chat has nothing to play it on).
          AudioFillerJson: channel === 'voice'
            ? { Enabled: true, AudioType: 'TYPING_QUIET_QWERTY', StartDelayInMilliseconds: 2500, MinimumPlayDurationInMilliseconds: 3000, ResponseDeliveryDelayInMilliseconds: 500 }
            : { Enabled: false },
        }),
      });

    this.chat = flow('ChatFlow', FLOWS.chat, 'chat');
    this.voice = flow('VoiceFlow', FLOWS.voice, 'voice');
  }
}

/** Fills the template's {{Placeholders}} (strings may be CDK tokens; objects replace a quoted placeholder). Throws on any left unfilled. */
function render(values: Record<string, string>, objects: Record<string, unknown> = {}): string {
  let content = JSON.stringify(JSON.parse(readFileSync(join(__dirname, '../flows/livesync.json'), 'utf8')));
  // Whole JSON values first: "{{Name}}" (quotes included) becomes the object itself.
  for (const [key, value] of Object.entries(objects)) content = content.split(`"{{${key}}}"`).join(JSON.stringify(value));
  for (const [key, value] of Object.entries(values)) content = content.split(`{{${key}}}`).join(value);
  const missing = content.match(/\{\{[A-Za-z]+\}\}/g);
  if (missing) throw new Error(`livesync.json: no value for ${[...new Set(missing)].join(', ')}`);
  return content;
}
