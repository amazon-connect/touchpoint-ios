import { CustomResource, Duration, RemovalPolicy, Stack } from 'aws-cdk-lib';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as nodejs from 'aws-cdk-lib/aws-lambda-nodejs';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import * as cr from 'aws-cdk-lib/custom-resources';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { Construct } from 'constructs';
import { ACXD, SECRET_PLACEHOLDER } from '../config';
import { disputeFlow } from '../dispute-flow';

export interface AcxdAppProps {
  /** The base stack's secret: apiKey and workspaceId (step 2). */
  readonly secret: secretsmanager.ISecret;
}

/**
 * Deploys the dispute AI agent into the Agentic CX Designer application you created in step 2, with
 * the Agentic CX Designer SDK, from a CloudFormation custom resource. Redeploys when the flow, the
 * action contract, or the handler changes.
 */
export class AcxdApp extends Construct {
  readonly workspaceId: string;
  readonly applicationId: string;
  readonly deploymentAlias: string;

  constructor(scope: Construct, id: string, props: AcxdAppProps) {
    super(scope, id);

    const entry = join(__dirname, '../../lambda/acxd-deploy/index.ts');
    const fn = new nodejs.NodejsFunction(this, 'DeployFunction', {
      description: 'Custom resource: deploys the dispute AI agent with the Agentic CX Designer SDK',
      entry,
      handler: 'handler',
      runtime: lambda.Runtime.NODEJS_24_X,
      architecture: lambda.Architecture.ARM_64,
      memorySize: 512,
      // Builds and deployments are polled until they finish.
      timeout: Duration.minutes(14),
      logGroup: new logs.LogGroup(this, 'DeployLogs', { retention: logs.RetentionDays.ONE_MONTH, removalPolicy: RemovalPolicy.DESTROY }),
      bundling: { minify: true, sourceMap: false },
    });
    props.secret.grantRead(fn);

    const provider = new cr.Provider(this, 'Provider', {
      onEventHandler: fn,
      logGroup: new logs.LogGroup(this, 'ProviderLogs', { retention: logs.RetentionDays.ONE_WEEK, removalPolicy: RemovalPolicy.DESTROY }),
    });

    const flowJson = JSON.stringify(disputeFlow());
    const deployment = new CustomResource(this, 'Deployment', {
      serviceToken: provider.serviceToken,
      resourceType: 'Custom::AcxdAppDeployment',
      properties: {
        SecretId: props.secret.secretArn,
        Region: Stack.of(this).region,
        ApplicationName: ACXD.applicationName,
        FlowId: ACXD.flowId,
        Environment: ACXD.environment,
        LanguageCode: ACXD.languageCode,
        ContextVariables: [...ACXD.contextVariables],
        FlowJson: flowJson,
        Placeholder: SECRET_PLACEHOLDER,
        // Re-runs when the handler changes, not only the flow.
        HandlerHash: createHash('sha256').update(readFileSync(entry)).digest('hex').slice(0, 16),
      },
    });

    this.workspaceId = deployment.getAttString('WorkspaceId');
    this.applicationId = deployment.getAttString('ApplicationId');
    this.deploymentAlias = deployment.getAttString('DeploymentAlias');
  }
}
