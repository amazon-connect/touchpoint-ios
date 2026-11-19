import { CfnOutput, Stack, StackProps } from 'aws-cdk-lib';
import * as cognito from 'aws-cdk-lib/aws-cognito';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import { Construct } from 'constructs';
import { AcxdApp } from './constructs/acxd-app';
import { AgentRouting } from './constructs/agent-routing';
import { ContactFlows } from './constructs/contact-flows';
import { DemoApi } from './constructs/demo-api';

export interface AgentStackProps extends StackProps {
  readonly instanceId: string;
  readonly userPool: cognito.IUserPool;
  readonly userPoolClient: cognito.IUserPoolClient;
  readonly secret: secretsmanager.ISecret;
}

/**
 * Step 3, after the console step. The dispute AI agent (Agentic CX Designer SDK), the chat and voice
 * contact flows that hand contacts to it, the queue and agent a hand-off goes to, and the API and
 * identity pool the demo app uses.
 */
export class AgentStack extends Stack {
  constructor(scope: Construct, id: string, props: AgentStackProps) {
    super(scope, id, props);

    const instanceArn = this.formatArn({ service: 'connect', resource: 'instance', resourceName: props.instanceId });
    const acxd = new AcxdApp(this, 'Acxd', { secret: props.secret });
    const agents = new AgentRouting(this, 'Agents', { instanceArn });
    const flows = new ContactFlows(this, 'Flows', { instanceId: props.instanceId, acxd, queueArn: agents.queue.attrQueueArn });
    const api = new DemoApi(this, 'DemoApi', {
      instanceId: props.instanceId,
      flows,
      deploymentAlias: acxd.deploymentAlias,
      secret: props.secret,
      userPool: props.userPool,
      userPoolClient: props.userPoolClient,
    });

    // What the demo app's live mode needs. None of these is a secret.
    new CfnOutput(this, 'ApiEndpoint', { value: api.api.apiEndpoint, description: 'Demo API base URL (SigV4, service execute-api)' });
    new CfnOutput(this, 'Region', { value: this.region });
    new CfnOutput(this, 'UserPoolId', { value: props.userPool.userPoolId });
    new CfnOutput(this, 'UserPoolClientId', { value: props.userPoolClient.userPoolClientId });
    new CfnOutput(this, 'IdentityPoolId', { value: api.identityPool.ref });
    new CfnOutput(this, 'LiveSyncDeploymentKey', {
      value: acxd.deploymentAlias,
      description: 'The Agentic CX Designer deployment alias; the Live Sync socket uses it as its deployment key',
    });
    new CfnOutput(this, 'ChatFlowArn', { value: flows.chat.attrContactFlowArn });
    new CfnOutput(this, 'VoiceFlowArn', { value: flows.voice.attrContactFlowArn });
  }
}
