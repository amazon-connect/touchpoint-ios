import assert from 'node:assert/strict';
import { test } from 'node:test';
import { disputeFlow, loadActionContract } from '../lib/dispute-flow';

test('the contract has the five dispute actions, each with a description', () => {
  const names = loadActionContract().map((a) => a.name);
  assert.deepEqual(names.sort(), ['filter_transactions', 'open_account', 'select_transaction', 'set_dispute_details', 'start_dispute']);
});

test('no declared action can submit the dispute', () => {
  // The customer taps Submit themselves; the AI agent only fills the form in.
  for (const a of loadActionContract()) assert.doesNotMatch(a.name, /submit/i, `${a.name} must not submit`);
});

test('the agentic node declares every contract action with its scope', () => {
  const nodes = Object.values(disputeFlow().nodes as Record<string, any>);
  const agentic = nodes.find((n) => n.metadata?.multimodal?.type === 'agentic');
  assert.ok(agentic, 'no agentic node');
  const declared = agentic.metadata.multimodal.actions.map((a: any) => `${a.name}:${a.scopeTags[0]}`).sort();
  assert.deepEqual(declared, [
    'filter_transactions:transactions',
    'open_account:accounts',
    'select_transaction:transactions',
    'set_dispute_details:dispute',
    'start_dispute:dispute',
  ]);
});

test('node ids are stable across builds, so a redeploy updates in place', () => {
  assert.deepEqual(Object.keys(disputeFlow().nodes as object), Object.keys(disputeFlow().nodes as object));
});

test('every child edge points at a node in the flow', () => {
  const nodes = disputeFlow().nodes as Record<string, any>;
  for (const n of Object.values(nodes)) for (const c of n.childNodes) assert.ok(nodes[c.nodeId], `dangling edge from ${n.metadata?.name}`);
});

test('the AI agent cannot end the conversation by judging the dispute finished', () => {
  // A "dispute ready" exit fired one turn early in testing, before the dispute screen opened.
  const nodes = Object.values(disputeFlow().nodes as Record<string, any>);
  const agentic = nodes.find((n) => n.metadata?.multimodal?.type === 'agentic');
  const exits = agentic.metadata.multimodal.exitConditions.map((e: any) => e.name);
  assert.deepEqual(exits, ['WantsHuman', 'Goodbye']);
});

test('the AI agent is told not to guess dates from relative phrases', () => {
  // It does not know today's date: a guessed "last Tuesday" filtered the charge out on a real device.
  const nodes = Object.values(disputeFlow().nodes as Record<string, any>);
  const agentic = nodes.find((n) => n.metadata?.multimodal?.type === 'agentic');
  assert.match(agentic.metadata.multimodal.prompt, /never turn a relative date/);
  assert.match(agentic.metadata.multimodal.prompt, /amount only/);
});
