// npm run destroy                       — removes both stacks
// npm run destroy -- --delete-acxd-app  — first deletes the acme-dispute application and its flow too
// The Agentic CX Designer workspace and the programmatic user are yours: remove the user in the console.
import { GetSecretValueCommand, SecretsManagerClient } from '@aws-sdk/client-secrets-manager';
import {
  AgenticCXDesignerClient,
  DeleteApplicationCommand,
  DeleteApplicationDeploymentCommand,
  DeleteFlowCommand,
  ListApplicationDeploymentsCommand,
  ListApplicationsCommand,
} from 'amazon-connect-acxd-sdk';
import { spawnSync } from 'node:child_process';
import { ACXD, SECRET_NAME, SECRET_PLACEHOLDER } from '../lib/config';
import { instanceId, main, prompt, region, ROOT } from './lib';

main(async () => {
  const r = region();
  const id = instanceId();
  const deleteApp = process.argv.includes('--delete-acxd-app');
  const answer = await prompt(`Delete the Touchpoint demo stacks${deleteApp ? ` and the ${ACXD.applicationName} application` : ''} in ${r}? Type "yes": `);
  if (answer !== 'yes') { console.log('Nothing deleted.'); return; }

  // The application first: its key lives in the secret the stacks are about to delete.
  if (deleteApp) {
    try {
      const s = JSON.parse((await new SecretsManagerClient({ region: r }).send(new GetSecretValueCommand({ SecretId: SECRET_NAME }))).SecretString ?? '{}');
      if (!s.apiKey || s.apiKey === SECRET_PLACEHOLDER) throw new Error('no API key in the secret');
      const acxd = new AgenticCXDesignerClient({ region: r, apiKey: s.apiKey, workspaceId: s.workspaceId });
      const app = ((await acxd.send(new ListApplicationsCommand({ maxResults: 100 }))).items ?? []).find((a) => a.name === ACXD.applicationName);
      if (app?.applicationId) {
        const deps = ((await acxd.send(new ListApplicationDeploymentsCommand({ applicationIdentifier: app.applicationId }))).items ?? []) as Array<{ deploymentId?: string }>;
        for (const d of deps) if (d.deploymentId) await acxd.send(new DeleteApplicationDeploymentCommand({ applicationIdentifier: app.applicationId, deploymentIdentifier: d.deploymentId }));
        await acxd.send(new DeleteApplicationCommand({ applicationIdentifier: app.applicationId }));
        console.log(`✔ Deleted the ${ACXD.applicationName} application`);
      }
      try { await acxd.send(new DeleteFlowCommand({ flowIdentifier: ACXD.flowId })); console.log(`✔ Deleted the ${ACXD.flowId} flow`); } catch { /* already gone */ }
    } catch (err) {
      console.log(`! Could not delete the application (${(err as Error).message}); delete it in Agentic CX Designer.`);
    }
  }

  const res = spawnSync('npx', ['cdk', 'destroy', '--all', '--force', '-c', `instanceId=${id}`], { cwd: ROOT, stdio: 'inherit', env: process.env });
  if (res.status !== 0) process.exit(res.status ?? 1);
  console.log('\n✔ Stacks deleted. Still yours to remove in the console: the programmatic user (Workspace > Users > API Access)' +
    (deleteApp ? '.' : ` and the ${ACXD.applicationName} application.`));
});
