// npm run doctor
// Read-only checks, in setup order, with the next step to take. Run it any time; it changes nothing.
import { CloudFormationClient, DescribeStacksCommand } from '@aws-sdk/client-cloudformation';
import { CognitoIdentityProviderClient, ListUsersCommand } from '@aws-sdk/client-cognito-identity-provider';
import { ConnectClient, DescribeInstanceAttributeCommand, DescribeInstanceCommand } from '@aws-sdk/client-connect';
import { GetSecretValueCommand, SecretsManagerClient } from '@aws-sdk/client-secrets-manager';
import { GetCallerIdentityCommand, STSClient } from '@aws-sdk/client-sts';
import { AgenticCXDesignerClient, GetWorkspaceCommand, ListApplicationsCommand } from 'amazon-connect-acxd-sdk';
import { ACXD, SECRET_NAME, SECRET_PLACEHOLDER } from '../lib/config';
import { instanceId, main, region, stackOutputs } from './lib';

let failed = false;
let next = '';
const ok = (msg: string) => console.log(`  ✔ ${msg}`);
const warn = (msg: string) => console.log(`  ! ${msg}`);
const bad = (msg: string, fix: string) => { console.log(`  ✖ ${msg}\n    → ${fix}`); failed = true; next ||= fix; };
const todo = (msg: string, step: string) => { console.log(`  · ${msg}`); next ||= step; };

main(async () => {
  console.log('Environment');
  const major = Number(process.versions.node.split('.')[0]);
  major >= 22 ? ok(`Node.js ${process.versions.node}`) : warn(`Node.js ${process.versions.node}: works today, but the AWS SDK needs 22+ from January 2027`);
  const r = region();
  const id = instanceId();
  ok(`Region ${r}, instance ${id}`);

  try {
    const who = await new STSClient({ region: r }).send(new GetCallerIdentityCommand({}));
    ok(`AWS credentials: ${who.Arn}`);
  } catch (err) {
    bad(`AWS credentials: ${(err as Error).name}`, 'Refresh your AWS credentials (or set AWS_PROFILE in .env).');
    return summary();
  }

  console.log('Amazon Connect');
  const connect = new ConnectClient({ region: r });
  try {
    const inst = (await connect.send(new DescribeInstanceCommand({ InstanceId: id }))).Instance;
    inst?.InstanceStatus === 'ACTIVE' ? ok(`Instance ${inst.InstanceAlias} is active`) : bad(`Instance status ${inst?.InstanceStatus}`, 'Use an active instance.');
    inst?.InboundCallsEnabled ? ok('Inbound calls enabled') : bad('Inbound calls are disabled', 'Enable inbound calls on the instance (needed for in-app calls).');
    if (process.env.CONNECT_INSTANCE_URL === undefined && inst?.InstanceAlias) warn(`Tip: CONNECT_INSTANCE_URL=https://${inst.InstanceAlias}.my.connect.aws in .env`);
    const logs = await connect.send(new DescribeInstanceAttributeCommand({ InstanceId: id, AttributeType: 'CONTACTFLOW_LOGS' }));
    logs.Attribute?.Value === 'true' ? ok('Flow logs on') : warn('Flow logs are off: turn them on to troubleshoot (instance > Data storage > Flow logs).');
  } catch (err) {
    bad(`Instance ${id}: ${(err as Error).name}`, `Check INSTANCE_ID and AWS_REGION (the instance must be in ${r}).`);
    return summary();
  }

  console.log('Deployment');
  const cfn = new CloudFormationClient({ region: r });
  try { await cfn.send(new DescribeStacksCommand({ StackName: 'CDKToolkit' })); ok('CDK bootstrapped'); }
  catch { bad('CDK is not bootstrapped in this account and Region', 'npx cdk bootstrap'); return summary(); }

  const base = await stackOutputs('base');
  if (!base) { todo('Base stack not deployed', 'npm run deploy:base'); return summary(); }
  ok('Base stack deployed');

  const users = await new CognitoIdentityProviderClient({ region: r }).send(new ListUsersCommand({ UserPoolId: base.UserPoolId, Limit: 1 }));
  (users.Users?.length ?? 0) > 0 ? ok('A demo user exists') : todo('No demo user yet', 'npm run create-user');

  const secret = JSON.parse((await new SecretsManagerClient({ region: r }).send(new GetSecretValueCommand({ SecretId: SECRET_NAME }))).SecretString ?? '{}') as Record<string, string>;
  const keysSet = secret.apiKey && secret.apiKey !== SECRET_PLACEHOLDER && secret.workspaceId && secret.workspaceId !== SECRET_PLACEHOLDER;
  if (!keysSet) { todo('Agentic CX Designer keys not set', 'Create the acme-dispute application and a programmatic user key in the console, then: npm run set-keys'); return summary(); }

  console.log('Agentic CX Designer');
  try {
    const acxd = new AgenticCXDesignerClient({ region: r, apiKey: secret.apiKey, workspaceId: secret.workspaceId });
    const ws = await acxd.send(new GetWorkspaceCommand({ workspaceId: secret.workspaceId }));
    ok(`Workspace ${ws.name ?? secret.workspaceId} opens with the API key`);
    const apps = (await acxd.send(new ListApplicationsCommand({ maxResults: 100 }))).items ?? [];
    apps.some((a) => a.name === ACXD.applicationName)
      ? ok(`Application ${ACXD.applicationName} found`)
      : bad(`No application named ${ACXD.applicationName}`, `Create it in Agentic CX Designer (exactly "${ACXD.applicationName}").`);
  } catch (err) {
    bad(`The API key cannot open the workspace (${(err as Error).name})`, 'Check the key and workspace id, then: npm run set-keys');
    return summary();
  }

  const agent = await stackOutputs('agent');
  if (!agent) { todo('Agent stack not deployed', 'npm run deploy'); return summary(); }
  ok(`Agent stack deployed: API ${agent.ApiEndpoint}`);
  secret.liveSyncApiKey && secret.liveSyncApiKey !== SECRET_PLACEHOLDER
    ? ok('Live Sync key set')
    : todo('Live Sync key not set', 'Copy acme-dispute > Settings > Access > API key, then: npm run set-livesync-key');
  todo('Check the API refuses anonymous callers', 'npm run verify');
  return summary();
});

function summary() {
  console.log(failed ? '\nFix the ✖ items above.' : '\nNo problems found.');
  if (next) console.log(`Next: ${next}`);
  if (failed) process.exitCode = 1;
}
