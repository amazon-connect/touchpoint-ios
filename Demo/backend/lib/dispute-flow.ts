import { createHash } from 'node:crypto';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { ACXD, BANK_NAME } from './config';

/**
 * The Agentic CX Designer flow for the card-dispute journey.
 *
 * start → greet → livesync (an agentic node that drives the app) → goodbye | lost | handoff → end
 *
 * There is deliberately no "dispute is ready" exit: the model can judge the dispute finished one turn
 * early and end the conversation before it has opened the dispute screen. The prompt asks it to tell
 * the customer to review and tap Submit, and the conversation stays open until they leave.
 *
 * The agentic node declares the app's five Live Sync actions from the files the Acme Bank app bundles
 * (`Demo/AcmeBank/Resources/ActionContract/*.schema.json`), so the AI agent and the app cannot drift apart. An action
 * the app advertises is only a tool the AI agent can call if this node declares it too.
 *
 * Node ids are derived from the flow id and the node's role, so a redeploy updates the flow in place.
 */

const CONTRACT_DIR = join(__dirname, '..', '..', 'AcmeBank', 'Resources', 'ActionContract');

/** The screen each action belongs to. The app advertises an action only while that screen shows. */
const SCOPE: Record<string, string> = {
  open_account: 'accounts',
  filter_transactions: 'transactions',
  select_transaction: 'transactions',
  start_dispute: 'dispute',
  set_dispute_details: 'dispute',
};

const PROMPT = `# ROLE
You are ${BANK_NAME}'s assistant, working alongside the bank's mobile app the customer is holding. You help them dispute a card charge they do not recognise.

# HOW TO WORK
The app tells you which screen it is on and which actions it allows there. You can only call an action the app is offering right now, and the app offers new actions only after the screen changes. Move the app with the customer, one step per turn:
1. When they mention a charge they do not recognise, call open_account (credit card unless they say otherwise).
2. As they describe the charge, call filter_transactions with the amount only. Speech is often misheard, and a wrong merchant or date hides the charge, so add merchant only if the customer clearly names a business, and never turn a relative date such as "last Tuesday" into a date (you do not know today's date). If the customer says they do not see the charge, call filter_transactions again with the amount alone, or with nothing to show every charge.
3. When they confirm which charge it is, call select_transaction. This opens the charge; it does not start a dispute.
4. When they want to dispute it: if start_dispute is offered, call it now, before asking why. If it is not offered yet, call select_transaction first and say "I've opened the charge. Shall I start the dispute?"; call start_dispute when they agree. The app asks the customer to confirm before the dispute screen opens.
5. set_dispute_details is only offered once the dispute screen is open. As they explain, call it with only the fields they actually stated.

# HONESTY
Only describe what an action actually did, after it ran. Never say the dispute screen or form is open, ready or filled unless start_dispute or set_dispute_details ran in this conversation. If the action you need is not offered, say what you will do next instead of pretending it happened.

# LIMITS
You cannot submit the dispute and must never say you have. When the form is filled, ask the customer to review it and tap Submit themselves. Never ask for card numbers, PINs, passwords or one-time codes.

# STYLE
Spoken, not written: no lists, no markdown. Two short sentences at most. Ask for one missing detail at a time.`;

function nodeId(role: string): string {
  const h = createHash('sha256').update(`acxd/${ACXD.flowId}/${role}`).digest();
  const b = Buffer.from(h.subarray(0, 16));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // RFC 4122 variant
  const hex = b.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

const canvas = (i: number) => ({ x: 0, y: 160 * i, width: 240, height: 120, isMinimized: false });
const message = (role: string, body: string) => ({ messageId: nodeId(`msg-${role}`), type: 'text', skipTranslation: false, body });
const child = (target: string, conditions: unknown[] = []) => ({ nodeId: nodeId(target), name: '', conditions });
const nodeStatus = (value: string) => [{ left: { type: 'node_status' }, operator: 'eq', right: { type: 'constant', value } }];
// Exit conditions are matched on a system variable, not on the node.
const exitIndex = (i: number) => [
  { left: { type: 'system', name: 'System.liveSyncConditionIndex' }, operator: 'eq', right: { type: 'constant', value: i } },
];

export interface ContractAction {
  name: string;
  description: string;
  schema: Record<string, unknown>;
}

/** The action contract, from the schema files. Throws if a file has no title, description, or scope. */
export function loadActionContract(dir = CONTRACT_DIR): ContractAction[] {
  return readdirSync(dir)
    .filter((f) => f.endsWith('.schema.json'))
    .sort()
    .map((f) => {
      const { $schema: _s, title, description, ...schema } = JSON.parse(readFileSync(join(dir, f), 'utf8'));
      if (typeof title !== 'string' || !SCOPE[title]) throw new Error(`${f}: title must be one of ${Object.keys(SCOPE).join(', ')}`);
      // An action without a description is invisible to the model: it would never be chosen.
      if (typeof description !== 'string' || !description.trim()) throw new Error(`${f}: description is required`);
      return { name: title, description, schema };
    });
}

/** The flow, as the Agentic CX Designer SDK's CreateFlow / UpdateFlow input (without flowIdentifier). */
export function disputeFlow(): Record<string, unknown> {
  const actions = loadActionContract().map((a) => ({
    type: 'custom',
    name: a.name,
    prompt: a.description,
    schema: a.schema,
    scopeTags: [SCOPE[a.name]],
  }));

  const basic = (role: string, i: number, say: string, next: string) => ({
    nodeId: nodeId(role), type: 'basic', modalities: {}, canvasMetadata: canvas(i),
    metadata: { name: role, stateModifications: [] }, messages: [message(role, say)], childNodes: [child(next)],
  });

  const nodes: Record<string, unknown> = {
    [nodeId('start')]: {
      nodeId: nodeId('start'), type: 'start', messages: [], modalities: {}, canvasMetadata: canvas(0),
      metadata: { stateModifications: [] }, childNodes: [child('greet')],
    },
    [nodeId('greet')]: basic('greet', 1, `Hi, this is ${BANK_NAME}. I can see your accounts. How can I help today?`, 'livesync'),
    [nodeId('livesync')]: {
      nodeId: nodeId('livesync'), type: 'multimodal', messages: [], modalities: {}, canvasMetadata: canvas(2),
      metadata: {
        name: 'livesync',
        stateModifications: [],
        interimMessages: [{ messageId: nodeId('livesync/interim'), text: 'One moment.', delay: 1500 }],
        multimodal: {
          type: 'agentic',
          prompt: PROMPT,
          actions,
          tools: [],
          exitConditions: [
            { name: 'WantsHuman', prompt: 'The customer explicitly asks to talk to a person, an agent or a human. Mentioning a charge, a card or a dispute is not a request for a person.' },
            { name: 'Goodbye', prompt: 'The customer explicitly says goodbye or that they are finished.' },
          ],
          maxSteps: 10,
          maxTokens: 8192,
          temperature: 0.1,
          smallTalk: false,
          piiMode: false,
          sessionStartTimeout: 120000,
          inactivityTimeout: 120000,
          automatedTags: [],
        },
      },
      childNodes: [
        child('handoff', exitIndex(0)),
        child('goodbye', exitIndex(1)),
        child('lost', nodeStatus('timeout')),
        child('handoff', nodeStatus('failure')),
      ],
    },
    [nodeId('goodbye')]: basic('goodbye', 4, `Thanks for banking with ${BANK_NAME}. Goodbye.`, 'end'),
    [nodeId('lost')]: basic('lost', 5, 'It seems we got disconnected. Come back any time.', 'end'),
    // Escalate returns to the contact flow on its Escalation branch.
    [nodeId('handoff')]: {
      nodeId: nodeId('handoff'), type: 'escalate', modalities: {}, canvasMetadata: canvas(6),
      metadata: { name: 'handoff', stateModifications: [] }, messages: [message('handoff', 'Let me pass you to our team.')], childNodes: [],
    },
    [nodeId('end')]: {
      nodeId: nodeId('end'), type: 'end', messages: [], modalities: {}, canvasMetadata: canvas(7),
      metadata: { stateModifications: [] }, childNodes: [],
    },
  };

  return {
    description: `${BANK_NAME} card dispute: the AI agent drives the mobile app through declared Live Sync actions`,
    untrained: true,
    mainLanguageCode: ACXD.languageCode,
    languageCodes: [ACXD.languageCode],
    nodes,
  };
}
