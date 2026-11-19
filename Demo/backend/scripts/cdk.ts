// Runs the CDK CLI with .env loaded, so INSTANCE_ID, AWS_REGION and AWS_PROFILE are set once.
//   npm run deploy:base      → cdk deploy TouchpointDemo
//   npm run deploy           → cdk deploy --all --outputs-file outputs.json
//   npm run synth / diff     → the same, read-only
import { spawnSync } from 'node:child_process';
import { instanceId, loadEnv, region, ROOT } from './lib';

loadEnv();
const args = process.argv.slice(2);
const id = instanceId();
region();
const r = spawnSync('npx', ['cdk', ...args, '-c', `instanceId=${id}`], { cwd: ROOT, stdio: 'inherit', env: process.env });
process.exit(r.status ?? 1);
