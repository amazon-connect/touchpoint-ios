// Shared by the npm scripts: .env loading, stack outputs, hidden prompts, and tidy failures.
import { CloudFormationClient, DescribeStacksCommand } from '@aws-sdk/client-cloudformation';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { AGENT_STACK_NAME, BASE_STACK_NAME } from '../lib/config';

export const ROOT = join(__dirname, '..');

/**
 * Loads `.env` (KEY=value lines; # comments) into process.env without overriding anything already
 * set, so `AWS_PROFILE=x npm run …` still wins. Also maps INSTANCE_ID for the CDK app.
 */
export function loadEnv(): void {
  const file = join(ROOT, '.env');
  if (existsSync(file)) {
    for (const raw of readFileSync(file, 'utf8').split('\n')) {
      const line = raw.trim();
      if (!line || line.startsWith('#')) continue;
      const eq = line.indexOf('=');
      if (eq < 1) continue;
      const key = line.slice(0, eq).trim();
      const value = line.slice(eq + 1).trim().replace(/^["']|["']$/g, '');
      if (process.env[key] === undefined) process.env[key] = value;
    }
  }
  // The AWS SDK and the CDK CLI read either name.
  if (process.env.AWS_REGION && !process.env.AWS_DEFAULT_REGION) process.env.AWS_DEFAULT_REGION = process.env.AWS_REGION;
}

export function region(): string {
  const r = process.env.AWS_REGION ?? process.env.AWS_DEFAULT_REGION;
  if (!r) fail('Set AWS_REGION in .env (the Region of your Amazon Connect instance).');
  return r;
}

export function instanceId(): string {
  const id = process.env.INSTANCE_ID;
  if (!id || !/^[0-9a-f-]{36}$/.test(id)) fail('Set INSTANCE_ID in .env to your Amazon Connect instance id.');
  return id;
}

/** A stack's outputs by key, or undefined when the stack is not deployed. */
export async function stackOutputs(stack: 'base' | 'agent'): Promise<Record<string, string> | undefined> {
  const StackName = stack === 'base' ? BASE_STACK_NAME : AGENT_STACK_NAME;
  try {
    const r = await new CloudFormationClient({ region: region() }).send(new DescribeStacksCommand({ StackName }));
    return Object.fromEntries((r.Stacks?.[0]?.Outputs ?? []).map((o) => [o.OutputKey!, o.OutputValue!]));
  } catch (err) {
    if ((err as Error).name === 'ValidationError') return undefined;
    throw err;
  }
}

export async function requireOutputs(stack: 'base' | 'agent'): Promise<Record<string, string>> {
  const out = await stackOutputs(stack);
  if (!out) fail(stack === 'base' ? 'Deploy the base stack first: npm run deploy:base' : 'Deploy the agent stack first: npm run deploy');
  return out;
}

/** Reads one line from the terminal. With `hidden`, typed characters are not echoed. */
export function prompt(question: string, hidden = false): Promise<string> {
  return new Promise((resolve) => {
    const stdin = process.stdin;
    process.stdout.write(question);
    if (!stdin.isTTY) {
      // Piped input: read a single line.
      let buf = '';
      stdin.setEncoding('utf8');
      const onData = (d: string) => {
        buf += d;
        const nl = buf.indexOf('\n');
        if (nl >= 0) { stdin.off('data', onData); stdin.pause(); resolve(buf.slice(0, nl).trim()); }
      };
      stdin.on('data', onData);
      return;
    }
    stdin.setRawMode(hidden);
    stdin.resume();
    stdin.setEncoding('utf8');
    let value = '';
    const onData = (chunk: string) => {
      for (const ch of chunk) {
        if (ch === '\r' || ch === '\n') {
          stdin.setRawMode(false); stdin.pause(); stdin.off('data', onData);
          process.stdout.write('\n'); resolve(value.trim()); return;
        }
        if (ch === '\u0003') { process.stdout.write('\n'); process.exit(130); }      // Ctrl-C
        if (ch === '\u007f' || ch === '\b') { if (value) { value = value.slice(0, -1); if (!hidden) process.stdout.write('\b \b'); } continue; }
        value += ch;
        if (!hidden) process.stdout.write(ch);
      }
    };
    stdin.on('data', onData);
  });
}

export function fail(message: string): never {
  console.error(`\n✖ ${message}`);
  process.exit(1);
}

/** Runs a script's main, turning thrown errors into one readable line. */
export function main(fn: () => Promise<void>): void {
  loadEnv();
  fn().catch((err) => fail(`${(err as Error).name}: ${(err as Error).message}`));
}
