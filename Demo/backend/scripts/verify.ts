// Verifies the deployed API refuses callers it should refuse, before it is used.
//
//   npm run verify
//
// 1. An anonymous request must get API Gateway's 403 (no signature).
// 2. A request signed with made-up credentials must get a 403 (invalid signature).
// 3. A request signed with your own AWS credentials must reach the function.
//
// Checks 1 and 2 run first. If either succeeds, the API is reachable without valid credentials: the
// script prints EXPOSED and exits non-zero without running check 3. Check 3 calls
// /livesync/credentials, which starts no contact; its response body is never printed.
import { Sha256 } from '@aws-crypto/sha256-js';
import { CloudFormationClient, DescribeStacksCommand } from '@aws-sdk/client-cloudformation';
import { fromNodeProviderChain } from '@aws-sdk/credential-providers';
import { SignatureV4 } from '@smithy/signature-v4';
import { randomBytes } from 'node:crypto';
import { AGENT_STACK_NAME } from '../lib/config';
import { loadEnv } from './lib';

loadEnv();

const PATH = '/livesync/credentials';

async function outputs(): Promise<Record<string, string>> {
  const r = await new CloudFormationClient({ region: process.env.AWS_REGION }).send(new DescribeStacksCommand({ StackName: AGENT_STACK_NAME }));
  return Object.fromEntries((r.Stacks?.[0]?.Outputs ?? []).map((o) => [o.OutputKey!, o.OutputValue!]));
}

async function signed(endpoint: URL, region: string, credentials: { accessKeyId: string; secretAccessKey: string; sessionToken?: string }) {
  const signer = new SignatureV4({ service: 'execute-api', region, credentials, sha256: Sha256 });
  const req = await signer.sign({
    method: 'POST',
    protocol: 'https:',
    hostname: endpoint.hostname,
    path: PATH,
    headers: { host: endpoint.hostname, 'content-type': 'application/json' },
    body: '{}',
  });
  return fetch(new URL(PATH, endpoint), { method: 'POST', headers: req.headers as Record<string, string>, body: '{}' });
}

async function main() {
  const out = await outputs();
  const endpoint = new URL(out.ApiEndpoint);
  const region = out.Region;
  let exposed = false;

  // 1. Anonymous.
  const anon = await fetch(new URL(PATH, endpoint), { method: 'POST', body: '{}', headers: { 'content-type': 'application/json' } });
  const anonBody = await anon.text();
  const anonOk = anon.status === 403 && /forbidden|missing authentication/i.test(anonBody);
  console.log(`1. anonymous request        -> ${anon.status} ${anonOk ? 'refused by the IAM gate' : 'NOT REFUSED'}`);
  exposed ||= !anonOk;

  // 2. Forged signature.
  // Made up on each run: well-formed, signed correctly, and belonging to nobody.
  const fake = (n: number) => randomBytes(n).toString('hex').toUpperCase().slice(0, n);
  const forged = await signed(endpoint, region, { accessKeyId: `AKIA${fake(16)}`, secretAccessKey: randomBytes(30).toString('base64') });
  await forged.text();
  const forgedOk = forged.status === 403;
  console.log(`2. forged-signature request -> ${forged.status} ${forgedOk ? 'refused' : 'NOT REFUSED'}`);
  exposed ||= !forgedOk;

  if (exposed) {
    console.error('EXPOSED: the API answered a request without valid credentials. Do not use it; check the routes\' AuthorizationType.');
    process.exit(1);
  }

  // 3. Signed with your own credentials.
  const ok = await signed(endpoint, region, await fromNodeProviderChain()());
  await ok.text(); // never printed: it carries the Live Sync key
  const reached = ok.status === 200 || ok.status === 503;
  console.log(
    `3. signed request           -> ${ok.status} ${
      ok.status === 200 ? 'reached the function; Live Sync is configured' :
      ok.status === 503 ? 'reached the function; liveSyncApiKey is not set yet (README step 4)' : 'UNEXPECTED'
    }`,
  );
  if (!reached) process.exit(1);
  console.log('OK: the API refuses unsigned and forged requests and accepts signed ones.');
}

main().catch((err) => {
  console.error((err as Error).message);
  process.exit(1);
});
