// npm run agent-password
// Copies the demo agent's initial password to the clipboard (macOS pbcopy, Linux xclip/wl-copy,
// Windows clip). It is printed only if no clipboard tool is found, and then only with --show.
import { GetSecretValueCommand, SecretsManagerClient } from '@aws-sdk/client-secrets-manager';
import { spawnSync } from 'node:child_process';
import { AGENTS } from '../lib/config';
import { fail, main, region, requireOutputs } from './lib';

main(async () => {
  const out = await requireOutputs('agent');
  const raw = (await new SecretsManagerClient({ region: region() }).send(new GetSecretValueCommand({ SecretId: out.AgentPasswordSecret }))).SecretString;
  const password = (JSON.parse(raw ?? '{}') as { password?: string }).password;
  if (!password) fail(`No password in ${out.AgentPasswordSecret}.`);

  const tools: Array<[string, string[]]> = [['pbcopy', []], ['wl-copy', []], ['xclip', ['-selection', 'clipboard']], ['clip', []]];
  for (const [cmd, args] of tools) {
    const r = spawnSync(cmd, args, { input: password });
    if (r.status === 0) {
      console.log(`✔ Copied the initial password for ${AGENTS.username} to the clipboard.`);
      console.log('  Sign in to the agent workspace and set a new password when asked.');
      return;
    }
  }
  if (process.argv.includes('--show')) console.log(password);
  else fail('No clipboard tool found. Run `npm run agent-password -- --show` to print it instead.');
});
