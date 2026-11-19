import { CfnOutput, Duration, RemovalPolicy, SecretValue, Stack, StackProps } from 'aws-cdk-lib';
import * as cognito from 'aws-cdk-lib/aws-cognito';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import { Construct } from 'constructs';
import { PROJECT_PREFIX, SECRET_NAME, SECRET_PLACEHOLDER } from './config';

/**
 * Step 1. Two things the rest needs before the console step:
 *
 * - The **user pool** the demo app signs in to. No self sign-up: you create the demo user yourself
 *   (README), so nobody else can get credentials for your API.
 * - The **secret** that holds the Agentic CX Designer keys. It starts with placeholder values; you
 *   paste the real ones in step 2, because those keys can only be created in the console.
 */
export class BaseStack extends Stack {
  readonly userPool: cognito.UserPool;
  readonly userPoolClient: cognito.UserPoolClient;
  readonly secret: secretsmanager.Secret;

  constructor(scope: Construct, id: string, props: StackProps) {
    super(scope, id, props);

    this.userPool = new cognito.UserPool(this, 'DemoUsers', {
      userPoolName: `${PROJECT_PREFIX}-users`,
      selfSignUpEnabled: false,
      signInAliases: { username: true },
      passwordPolicy: { minLength: 12, requireDigits: true, requireLowercase: true, requireUppercase: true, requireSymbols: false },
      accountRecovery: cognito.AccountRecovery.NONE,
      featurePlan: cognito.FeaturePlan.ESSENTIALS,
      removalPolicy: RemovalPolicy.DESTROY,
    });

    // The demo app signs in with username and password straight to Cognito (no hosted UI), so the
    // client has no secret: a mobile app cannot keep one.
    this.userPoolClient = this.userPool.addClient('DemoApp', {
      userPoolClientName: `${PROJECT_PREFIX}-app`,
      generateSecret: false,
      authFlows: { userPassword: true },
      preventUserExistenceErrors: true,
      accessTokenValidity: Duration.hours(1),
      idTokenValidity: Duration.hours(1),
      refreshTokenValidity: Duration.days(1),
    });

    // Placeholders, not credentials: step 2 replaces them, and the agent stack refuses to deploy
    // until it has.
    this.secret = new secretsmanager.Secret(this, 'AcxdKeys', {
      secretName: SECRET_NAME,
      description:
        'Agentic CX Designer keys for the Touchpoint demo. apiKey: programmatic user key (deploys the AI agent). ' +
        'workspaceId: from the console URL. liveSyncApiKey: the application API key the app\'s Live Sync socket uses.',
      secretObjectValue: {
        apiKey: SecretValue.unsafePlainText(SECRET_PLACEHOLDER),
        workspaceId: SecretValue.unsafePlainText(SECRET_PLACEHOLDER),
        liveSyncApiKey: SecretValue.unsafePlainText(SECRET_PLACEHOLDER),
      },
      removalPolicy: RemovalPolicy.DESTROY,
    });

    new CfnOutput(this, 'UserPoolId', { value: this.userPool.userPoolId });
    new CfnOutput(this, 'UserPoolClientId', { value: this.userPoolClient.userPoolClientId });
    new CfnOutput(this, 'SecretName', {
      value: this.secret.secretName,
      description: 'Paste the Agentic CX Designer keys and workspace id here (README step 2)',
    });
  }
}
