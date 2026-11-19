import { CfnResource, IAspect, Aspects, Stack, Validations } from 'aws-cdk-lib';
import { AwsSolutionsChecks } from 'cdk-nag';
import { IConstruct } from 'constructs';

/**
 * Security checks on every synth, and the findings this demo accepts, each with its reason.
 *
 * cdk-nag's AWS Solutions pack runs on both stacks; an unacknowledged error fails `cdk synth` (and so
 * CI). The same accepted findings are written into the templates' Metadata for Checkov and
 * cfn-guard, so a scan of the synthesized templates (for example with Automated Security Helper)
 * reports them as suppressed rather than open.
 *
 * Everything accepted here is a cost or an operational choice for a short-lived demo in your own
 * account, not a gap in who can reach what: every API route still requires AWS_IAM, and every role
 * is scoped to this demo's resources.
 */
export function applySecurityChecks(app: IConstruct, base: Stack, agent: Stack): void {
  Validations.of(app).addPlugins(new AwsSolutionsChecks(app, { writeSuppressionsToCloudFormation: true }));

  acknowledge(base, {
    'AwsSolutions-COG2': 'Demo users are synthetic, created by the deployer, and the demo app signs in with a username and password only. A production app uses its own sign-in, with MFA.',
    'AwsSolutions-COG8': 'The Essentials feature plan keeps the demo free to run; threat protection (Plus) is a paid feature this demo does not need.',
    'AwsSolutions-SMG4': 'The secret holds Agentic CX Designer API keys, which are created and rotated in its console only; there is no API a rotation function could call.',
  });

  acknowledge(agent, {
    'AwsSolutions-IAM4[Policy::arn:<AWS::Partition>:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole]':
      'The managed basic execution policy grants CloudWatch Logs writes only.',
    'AwsSolutions-IAM5[Resource::<AcxdDeployFunctionA93E55FD.Arn>:*]':
      "The CDK custom resource framework may invoke any version of the one deploy function it fronts.",
    'AwsSolutions-L1': "The CDK custom resource framework's own function: its runtime is set by aws-cdk-lib. The demo's functions use the latest Node.js runtime.",
    'AwsSolutions-SMG4': "The agent's initial password: the agent sets a new one at first sign-in, so the stored value is never used again.",
  });

  Aspects.of(app).add(new ScannerSuppressions());
}

function acknowledge(scope: IConstruct, findings: Record<string, string>): void {
  for (const [id, reason] of Object.entries(findings)) Validations.of(scope).acknowledge({ id, reason });
}

/** Template Metadata for Checkov and cfn-guard, by resource type: the same choices as above. */
const ACCEPTED: Record<string, { checkov: Array<[string, string]>; guard: string[] }> = {
  'AWS::Lambda::Function': {
    checkov: [
      ['CKV_AWS_117', 'Calls only public AWS APIs; a VPC would add NAT cost and nothing to protect.'],
      ['CKV_AWS_116', 'Invoked synchronously (API Gateway, CloudFormation); errors return to the caller, so a dead-letter queue never receives anything.'],
      ['CKV_AWS_115', 'API Gateway throttles the API; reserved concurrency can fail the deploy on accounts with the minimum concurrency limit.'],
      ['CKV_AWS_173', 'Environment variables hold resource ids only, never secrets; Lambda encrypts them at rest with an AWS managed key.'],
    ],
    guard: ['LAMBDA_INSIDE_VPC'],
  },
  'AWS::Logs::LogGroup': {
    checkov: [['CKV_AWS_158', 'CloudWatch Logs encrypts log data at rest by default; the logs hold no request bodies or tokens.']],
    guard: ['CLOUDWATCH_LOG_GROUP_ENCRYPTED'],
  },
  'AWS::SecretsManager::Secret': {
    checkov: [['CKV_AWS_149', 'Encrypted with the AWS managed Secrets Manager key; a customer managed key adds cost and no access boundary for a demo.']],
    guard: [],
  },
};

class ScannerSuppressions implements IAspect {
  visit(node: IConstruct): void {
    if (!(node instanceof CfnResource)) return;
    const accepted = ACCEPTED[node.cfnResourceType];
    if (!accepted) return;
    node.addMetadata('checkov', { skip: accepted.checkov.map(([id, comment]) => ({ id, comment })) });
    if (accepted.guard.length) node.addMetadata('guard', { SuppressedRules: accepted.guard });
  }
}
