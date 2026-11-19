// Every name and setting in one place. Review before the first deploy.

/** CloudFormation stack names. Step 1 deploys BASE; step 3 deploys both. */
export const BASE_STACK_NAME = 'TouchpointDemo';
export const AGENT_STACK_NAME = 'TouchpointDemoAgent';

/** Prefix for resource names and the secret, so two copies can share an account. */
export const PROJECT_PREFIX = 'touchpoint-demo';

/**
 * The Agentic CX Designer names you create in the console (README step 2). The deploy finds the
 * application by name, so these must match exactly.
 */
export const ACXD = {
  applicationName: 'acme-dispute',
  /** Lowercase letters only: Agentic CX Designer flow ids allow no digits or separators. */
  flowId: 'acmedispute',
  environment: 'production',
  languageCode: 'en-US',
  /** Context variables the contact flows pass in. Created in the workspace if missing. */
  contextVariables: ['channel', 'screen', 'transactionId'],
} as const;

/** The secret step 2 fills in. Created by the base stack with placeholder values. */
export const SECRET_NAME = `${PROJECT_PREFIX}/acxd`;
export const SECRET_PLACEHOLDER = 'REPLACE_ME';

/** Contact flow names in your Amazon Connect instance. */
export const FLOWS = {
  chat: `${PROJECT_PREFIX}-chat-livesync`,
  voice: `${PROJECT_PREFIX}-voice-livesync`,
} as const;

/**
 * The human side, for hand-offs and screen sharing. One agent user; sign in to the agent workspace
 * as this user to take an escalated chat or call and to view the customer's shared screen.
 */
export const AGENTS = {
  username: 'touchpoint-agent',
  timeZone: 'America/New_York',
} as const;

/**
 * The AI agent's spoken voice on calls: Amazon Connect agentic voice. The voice must exist for the
 * AI agent's language (en-US); pick one in the Set voice block's dropdown to see the list.
 */
export const VOICE = { name: 'Danielle', engine: 'connect:agentic' } as const;

/** What the bank is called in the AI agent's greeting and prompt. */
export const BANK_NAME = 'Acme Bank';

/** API Gateway stage throttling: a demo needs very little, and an abused key can do little. */
export const API_THROTTLE = { rateLimit: 5, burstLimit: 10 } as const;

/** Tags on every resource, for cost reports and clean-up. */
export const TAGS: Record<string, string> = {
  Project: PROJECT_PREFIX,
  ManagedBy: 'aws-cdk',
};
