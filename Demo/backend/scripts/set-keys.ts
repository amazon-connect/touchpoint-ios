// npm run set-keys          — the programmatic user's API key and the workspace id (before `npm run deploy`)
// npm run set-livesync-key  — the acme-dispute application's API key (after `npm run deploy`)
// Keys are typed without echo and go straight into Secrets Manager.
import { GetSecretValueCommand, PutSecretValueCommand, SecretsManagerClient } from '@aws-sdk/client-secrets-manager';
import { SECRET_NAME, SECRET_PLACEHOLDER } from '../lib/config';
import { fail, main, prompt, region, requireOutputs } from './lib';

main(async () => {
  await requireOutputs('base');
  const sm = new SecretsManagerClient({ region: region() });
  const current = JSON.parse((await sm.send(new GetSecretValueCommand({ SecretId: SECRET_NAME }))).SecretString ?? '{}') as Record<string, string>;
  const which = process.argv[2] === 'livesync' ? 'livesync' : 'acxd';

  if (which === 'acxd') {
    console.log('From Agentic CX Designer: Workspace > Users > API Access (programmatic user, Workspace administrator).');
    const apiKey = await prompt('Programmatic user API key: ', true);
    if (!/^acxd_live_[A-Za-z0-9._-]{8,}$/.test(apiKey)) fail('That does not look like an Agentic CX Designer API key (acxd_live_…).');
    console.log('The workspace id is in the browser URL: …/acxd/w/<workspace-id>/applications');
    const workspaceId = await prompt('Workspace id: ');
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(workspaceId)) fail('That does not look like a workspace id (a UUID).');
    await sm.send(new PutSecretValueCommand({
      SecretId: SECRET_NAME,
      SecretString: JSON.stringify({ ...current, apiKey, workspaceId, liveSyncApiKey: current.liveSyncApiKey ?? SECRET_PLACEHOLDER }),
    }));
    console.log('✔ Saved. Next: npm run deploy');
  } else {
    console.log('From Agentic CX Designer: Applications > acme-dispute > Settings > Access > API key.');
    const key = await prompt('acme-dispute application API key: ', true);
    if (!/^[A-Za-z0-9_-]{16,128}$/.test(key)) fail('That does not look like an application API key (16-128 letters, digits, _ or -).');
    await sm.send(new PutSecretValueCommand({ SecretId: SECRET_NAME, SecretString: JSON.stringify({ ...current, liveSyncApiKey: key }) }));
    console.log('✔ Saved. Next: npm run verify');
  }
});
