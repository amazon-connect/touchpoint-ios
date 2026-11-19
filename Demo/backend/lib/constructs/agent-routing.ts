import { CfnOutput, RemovalPolicy, aws_connect as connect, aws_secretsmanager as secretsmanager } from 'aws-cdk-lib';
import { Construct } from 'constructs';
import { AGENTS, PROJECT_PREFIX } from '../config';

export interface AgentRoutingProps {
  readonly instanceArn: string;
}

/**
 * Where a contact goes when the AI agent hands it to a person: always-open hours, a queue, a routing
 * profile for voice and chat, and one agent user who can accept in-app calls and view a shared screen.
 *
 * - The security profile grants `BasicAgentAccess` (the agent workspace) and `VideoContact.Access`
 *   (in-app video and screen sharing) and nothing else.
 * - The agent's initial password is generated in Secrets Manager. Amazon Connect accepts a password
 *   only when the user is created, so the agent changes it at first sign-in; it is never in code.
 */
export class AgentRouting extends Construct {
  readonly queue: connect.CfnQueue;

  constructor(scope: Construct, id: string, props: AgentRoutingProps) {
    super(scope, id);
    const { instanceArn } = props;

    // Own 24/7 hours: the instance's default "Basic Hours" has no id CloudFormation can reference.
    const days = ['MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY', 'FRIDAY', 'SATURDAY', 'SUNDAY'];
    const hours = new connect.CfnHoursOfOperation(this, 'AlwaysOpen', {
      instanceArn,
      name: `${PROJECT_PREFIX}-always-open`,
      description: 'Always open (24/7) for the Touchpoint demo',
      timeZone: AGENTS.timeZone,
      config: days.map((day) => ({ day, startTime: { hours: 0, minutes: 0 }, endTime: { hours: 0, minutes: 0 } })),
    });

    this.queue = new connect.CfnQueue(this, 'SupportQueue', {
      instanceArn,
      name: `${PROJECT_PREFIX}-support`,
      description: 'Touchpoint demo: chats and in-app calls the AI agent hands to a person',
      hoursOfOperationArn: hours.attrHoursOfOperationArn,
    });

    const routingProfile = new connect.CfnRoutingProfile(this, 'AgentsRoutingProfile', {
      instanceArn,
      name: `${PROJECT_PREFIX}-agents`,
      description: 'Touchpoint demo agents: one in-app call or two chats at a time',
      defaultOutboundQueueArn: this.queue.attrQueueArn,
      mediaConcurrencies: [
        { channel: 'VOICE', concurrency: 1 },
        { channel: 'CHAT', concurrency: 2 },
      ],
      queueConfigs: [
        { delay: 0, priority: 1, queueReference: { channel: 'VOICE', queueArn: this.queue.attrQueueArn } },
        { delay: 0, priority: 1, queueReference: { channel: 'CHAT', queueArn: this.queue.attrQueueArn } },
      ],
    });

    const securityProfile = new connect.CfnSecurityProfile(this, 'AgentSecurityProfile', {
      instanceArn,
      securityProfileName: `${PROJECT_PREFIX}-agent`,
      description: 'Touchpoint demo agent: agent workspace, in-app calls, and viewing a shared screen',
      permissions: ['BasicAgentAccess', 'VideoContact.Access'],
    });

    const password = new secretsmanager.Secret(this, 'AgentPassword', {
      secretName: `${PROJECT_PREFIX}/agent-password`,
      description: `Initial password for the Touchpoint demo agent ${AGENTS.username}. Change it at first sign-in.`,
      generateSecretString: {
        secretStringTemplate: JSON.stringify({ username: AGENTS.username }),
        generateStringKey: 'password',
        passwordLength: 24,
        // Connect passwords: upper, lower and a digit; no symbols keeps every shell happy.
        excludePunctuation: true,
        requireEachIncludedType: true,
      },
      removalPolicy: RemovalPolicy.DESTROY,
    });

    new connect.CfnUser(this, 'Agent', {
      instanceArn,
      username: AGENTS.username,
      // A CloudFormation dynamic reference to the secret, not the value.
      password: password.secretValueFromJson('password').unsafeUnwrap(),
      identityInfo: { firstName: 'Touchpoint', lastName: 'Agent' },
      phoneConfig: { phoneType: 'SOFT_PHONE', autoAccept: false, afterContactWorkTimeLimit: 0 },
      routingProfileArn: routingProfile.attrRoutingProfileArn,
      securityProfileArns: [securityProfile.attrSecurityProfileArn],
    });

    new CfnOutput(scope, 'AgentUsername', { value: AGENTS.username });
    new CfnOutput(scope, 'AgentPasswordSecret', {
      value: password.secretName,
      description: 'The agent\'s initial password (Secrets Manager). Change it at first sign-in.',
    });
  }
}
