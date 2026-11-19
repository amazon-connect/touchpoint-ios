// Custom resource: deploys the dispute AI agent into your Agentic CX Designer application.
//
// Reads the programmatic user's API key and the workspace id from Secrets Manager, then, with the
// Agentic CX Designer SDK: checks the workspace, finds the application by name, creates any missing
// context variables, creates or updates the flow, makes it the application's welcome flow, builds,
// and deploys to the environment. Returns the deployment alias, which the contact flows' Agentic CX
// Designer block needs and which the app's Live Sync socket uses as its deployment key.
//
// The workspace and the application are created by you in the console (README step 2), so a delete
// leaves them in place.
import { GetSecretValueCommand, SecretsManagerClient } from '@aws-sdk/client-secrets-manager';
import type { CloudFormationCustomResourceEvent } from 'aws-lambda';
import {
  AgenticCXDesignerClient,
  CreateApplicationBuildCommand,
  CreateApplicationDeploymentCommand,
  CreateContextVariableCommand,
  CreateFlowCommand,
  GetApplicationBuildCommand,
  GetApplicationDeploymentCommand,
  GetFlowCommand,
  GetWorkspaceCommand,
  ListApplicationDeploymentsCommand,
  ListApplicationsCommand,
  ListContextVariablesCommand,
  UpdateApplicationCommand,
  UpdateApplicationDeploymentCommand,
  UpdateFlowCommand,
} from 'amazon-connect-acxd-sdk';

interface Props {
  SecretId: string;
  Region: string;
  ApplicationName: string;
  FlowId: string;
  Environment: string;
  LanguageCode: string;
  ContextVariables: string[];
  /** One string, so CloudFormation does not turn the flow's numbers into strings. */
  FlowJson: string;
  Placeholder: string;
}

const POLL_MS = 5000;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
// Never log request bodies or keys: names and statuses only.
const log = (msg: string, data: Record<string, unknown> = {}) => console.log(JSON.stringify({ msg, ...data }));

async function loadSecret(secretId: string, placeholder: string): Promise<{ apiKey: string; workspaceId: string }> {
  const raw = (await new SecretsManagerClient({}).send(new GetSecretValueCommand({ SecretId: secretId }))).SecretString;
  const s = JSON.parse(raw ?? '{}') as Record<string, string>;
  if (!s.apiKey || s.apiKey === placeholder || !s.workspaceId || s.workspaceId === placeholder) {
    throw new Error(
      `Secret ${secretId} still has placeholder values. Paste the Agentic CX Designer programmatic user's API key ` +
        `(apiKey) and your workspace id (workspaceId) into it, then deploy again (README step 2).`,
    );
  }
  return { apiKey: s.apiKey, workspaceId: s.workspaceId };
}

async function waitFor<T>(what: string, get: () => Promise<T>, done: (r: T) => boolean, failed: (r: T) => boolean, status: (r: T) => unknown) {
  for (let i = 0; i < 120; i++) {
    const r = await get();
    if (done(r)) return r;
    if (failed(r)) throw new Error(`${what} failed: ${String(status(r))}`);
    await sleep(POLL_MS);
  }
  throw new Error(`${what} did not finish in time`);
}

async function deploy(p: Props): Promise<Record<string, string>> {
  const { apiKey, workspaceId } = await loadSecret(p.SecretId, p.Placeholder);
  const client = new AgenticCXDesignerClient({ region: p.Region, apiKey, workspaceId });

  // Workspace: fail with a clear message if the key cannot open it.
  try {
    await client.send(new GetWorkspaceCommand({ workspaceId }));
  } catch (err) {
    throw new Error(
      `The API key cannot open workspace ${workspaceId} (${(err as Error).name}). Check the key is not revoked, ` +
        'the workspace id is right, and the programmatic user is Workspace administrator on that workspace.',
    );
  }

  // Application: created by you in the console, found here by name.
  const apps = (await client.send(new ListApplicationsCommand({ maxResults: 100 }))).items ?? [];
  const app = apps.find((a) => a.name === p.ApplicationName);
  if (!app?.applicationId) {
    throw new Error(`No application named "${p.ApplicationName}" in the workspace. Create it in Agentic CX Designer (README step 2).`);
  }
  const applicationIdentifier = app.applicationId;

  // Context variables the contact flows pass in.
  const existing = new Set(((await client.send(new ListContextVariablesCommand({}))).items ?? []).map((v) => v.name));
  for (const name of p.ContextVariables.filter((n) => !existing.has(n))) {
    await client.send(new CreateContextVariableCommand({ name, schema: { type: 'string', isSensitive: false }, disallowExternalModification: false }));
    log('context variable created', { name });
  }

  // The flow: update in place if it exists.
  const flow = JSON.parse(p.FlowJson) as Record<string, unknown>;
  let exists = true;
  try {
    await client.send(new GetFlowCommand({ flowIdentifier: p.FlowId }));
  } catch {
    exists = false;
  }
  if (exists) await client.send(new UpdateFlowCommand({ flowIdentifier: p.FlowId, ...flow } as never));
  else await client.send(new CreateFlowCommand({ flowId: p.FlowId, ...flow } as never));
  log(exists ? 'flow updated' : 'flow created', { flowId: p.FlowId });

  // The flow is the application's welcome flow. One update: splitting flows and settings drops settings.
  await client.send(
    new UpdateApplicationCommand({
      applicationIdentifier,
      flows: [{ flowId: p.FlowId }],
      // The SDK member is `welcome`; it goes on the wire as "ACXD.Welcome".
      settings: { defaultFlows: { welcome: { flowId: p.FlowId } } },
    } as never),
  );

  // Build, then deploy (update the environment's deployment if there is one).
  const build = await client.send(new CreateApplicationBuildCommand({ applicationIdentifier, description: 'Deployed by AWS CDK' }));
  const buildIdentifier = (build as { buildId?: string }).buildId;
  if (!buildIdentifier) throw new Error('The build was not created');
  await waitFor(
    'Build',
    () => client.send(new GetApplicationBuildCommand({ applicationIdentifier, buildIdentifier })) as Promise<{ status?: string }>,
    (r) => r.status === 'BUILT',
    (r) => /fail/i.test(r.status ?? ''),
    (r) => r.status,
  );
  log('built', { buildIdentifier });

  const deployments = ((await client.send(new ListApplicationDeploymentsCommand({ applicationIdentifier }))).items ?? []) as Array<{
    deploymentId?: string;
    environment?: string;
  }>;
  const current = deployments.find((d) => d.environment === p.Environment);
  const common = {
    applicationIdentifier,
    buildIdentifier,
    environment: p.Environment,
    languageCodes: [p.LanguageCode],
    description: 'Deployed by AWS CDK',
  };
  const started = (await (current?.deploymentId
    ? client.send(new UpdateApplicationDeploymentCommand({ ...common, deploymentIdentifier: current.deploymentId } as never))
    : client.send(new CreateApplicationDeploymentCommand(common as never)))) as { deploymentId?: string };
  const deploymentIdentifier = started.deploymentId ?? current?.deploymentId;
  if (!deploymentIdentifier) throw new Error('The deployment was not created');

  const deployed = await waitFor(
    'Deployment',
    () =>
      client.send(new GetApplicationDeploymentCommand({ applicationIdentifier, deploymentIdentifier })) as Promise<{
        deploymentStatus?: string;
        deploymentAlias?: string;
      }>,
    (r) => r.deploymentStatus === 'deployed',
    (r) => /fail|error/i.test(r.deploymentStatus ?? ''),
    (r) => r.deploymentStatus,
  );
  if (!deployed.deploymentAlias) throw new Error(`Deployment ${deploymentIdentifier} has no alias`);
  log('deployed', { deploymentIdentifier, environment: p.Environment });

  return { WorkspaceId: workspaceId, ApplicationId: applicationIdentifier, DeploymentAlias: deployed.deploymentAlias };
}

export const handler = async (event: CloudFormationCustomResourceEvent) => {
  log('event', { requestType: event.RequestType, logicalResourceId: event.LogicalResourceId });
  if (event.RequestType === 'Delete') {
    // The application belongs to you (you created it in the console): leave it in place.
    return { PhysicalResourceId: event.PhysicalResourceId };
  }
  const props = event.ResourceProperties as unknown as Props;
  const data = await deploy(props);
  return { PhysicalResourceId: `${data.WorkspaceId}/${data.ApplicationId}`, Data: data };
};
