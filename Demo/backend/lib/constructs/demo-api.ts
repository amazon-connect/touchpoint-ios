import { Duration, Fn, RemovalPolicy, Stack } from 'aws-cdk-lib';
import * as apigw from 'aws-cdk-lib/aws-apigatewayv2';
import { HttpIamAuthorizer } from 'aws-cdk-lib/aws-apigatewayv2-authorizers';
import { HttpLambdaIntegration } from 'aws-cdk-lib/aws-apigatewayv2-integrations';
import * as cognito from 'aws-cdk-lib/aws-cognito';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as nodejs from 'aws-cdk-lib/aws-lambda-nodejs';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import { join } from 'node:path';
import { Construct } from 'constructs';
import { API_THROTTLE, PROJECT_PREFIX, SECRET_PLACEHOLDER } from '../config';
import { ContactFlows } from './contact-flows';

export interface DemoApiProps {
  readonly instanceId: string;
  readonly flows: ContactFlows;
  readonly deploymentAlias: string;
  readonly secret: secretsmanager.ISecret;
  readonly userPool: cognito.IUserPool;
  readonly userPoolClient: cognito.IUserPoolClient;
}

/**
 * The API the demo app calls, and the sign-in that lets it.
 *
 * - **HTTP API, AWS_IAM on every route.** API Gateway rejects any request that is not SigV4-signed by a
 *   principal allowed to invoke it, before the function runs. There is no unauthenticated route and no
 *   default route.
 * - **Identity pool, signed-in users only.** A demo user signs in to the user pool; the identity pool
 *   trades their ID token for temporary credentials whose role can call this API and nothing else.
 *   Guest access and the basic (classic) flow are off.
 * - **The function's own role** calls Amazon Connect, on your one instance and these two flows only.
 *
 * A production app does not hand AWS credentials to the device: it authenticates its own users and
 * its own backend starts the contact. This shape exists so a sample can reach a real instance with no
 * app server of its own.
 */
/** The demo API's routes, all POST and all AWS_IAM. */
const ROUTES = ['/chat/start', '/voice/start', '/livesync/credentials'];

export class DemoApi extends Construct {
  readonly api: apigw.HttpApi;
  readonly identityPool: cognito.CfnIdentityPool;

  constructor(scope: Construct, id: string, props: DemoApiProps) {
    super(scope, id);
    const stack = Stack.of(this);
    const instanceArn = props.flows.instanceArn;

    const fn = new nodejs.NodejsFunction(this, 'Handler', {
      description: 'Touchpoint demo API: starts chat and in-app voice contacts, vends Live Sync credentials',
      entry: join(__dirname, '../../lambda/demo-api/index.ts'),
      handler: 'handler',
      runtime: lambda.Runtime.NODEJS_24_X,
      architecture: lambda.Architecture.ARM_64,
      memorySize: 256,
      timeout: Duration.seconds(10),
      logGroup: new logs.LogGroup(this, 'HandlerLogs', { retention: logs.RetentionDays.ONE_MONTH, removalPolicy: RemovalPolicy.DESTROY }),
      environment: {
        INSTANCE_ID: props.instanceId,
        CHAT_FLOW_ID: flowId(props.flows.chat),
        VOICE_FLOW_ID: flowId(props.flows.voice),
        SECRET_ID: props.secret.secretArn,
        DEPLOYMENT_KEY: props.deploymentAlias,
        SECRET_PLACEHOLDER,
      },
      // A current @aws-sdk/client-connect (StartWebRTCContact), bundled rather than the runtime's copy.
      bundling: { minify: true, sourceMap: false, externalModules: [] },
    });
    // Least privilege: two actions, one instance, the two flows.
    fn.addToRolePolicy(
      new iam.PolicyStatement({
        actions: ['connect:StartChatContact'],
        resources: [instanceArn, props.flows.chat.attrContactFlowArn],
      }),
    );
    fn.addToRolePolicy(
      new iam.PolicyStatement({
        actions: ['connect:StartWebRTCContact'],
        resources: [instanceArn, props.flows.voice.attrContactFlowArn],
      }),
    );
    props.secret.grantRead(fn);

    const integration = new HttpLambdaIntegration('Integration', fn);
    const authorizer = new HttpIamAuthorizer();

    this.api = new apigw.HttpApi(this, 'Api', {
      apiName: `${PROJECT_PREFIX}-api`,
      description: 'Touchpoint demo API. Every route requires AWS_IAM (SigV4).',
      createDefaultStage: false,
    });
    for (const path of ROUTES) {
      this.api.addRoutes({ path, methods: [apigw.HttpMethod.POST], integration, authorizer });
    }

    const accessLogs = new logs.LogGroup(this, 'AccessLogs', { retention: logs.RetentionDays.ONE_MONTH, removalPolicy: RemovalPolicy.DESTROY });
    const stage = new apigw.HttpStage(this, 'Stage', {
      httpApi: this.api,
      stageName: '$default',
      autoDeploy: true,
      throttle: API_THROTTLE,
    });
    // Who called, and when. Identity only: no request bodies, no tokens.
    const cfnStage = stage.node.defaultChild as apigw.CfnStage;
    cfnStage.accessLogSettings = {
      destinationArn: accessLogs.logGroupArn,
      format: JSON.stringify({
        t: '$context.requestTime',
        id: '$context.requestId',
        ip: '$context.identity.sourceIp',
        user: '$context.identity.userArn',
        route: '$context.routeKey',
        status: '$context.status',
        err: '$context.error.message',
      }),
    };

    this.identityPool = new cognito.CfnIdentityPool(this, 'IdentityPool', {
      identityPoolName: `${PROJECT_PREFIX}-app`.replace(/-/g, '_'),
      allowUnauthenticatedIdentities: false,
      allowClassicFlow: false,
      cognitoIdentityProviders: [
        {
          clientId: props.userPoolClient.userPoolClientId,
          providerName: props.userPool.userPoolProviderName,
          serverSideTokenCheck: true,
        },
      ],
    });

    const appUserRole = new iam.Role(this, 'AppUserRole', {
      description: 'Signed-in demo app users: execute-api:Invoke on the demo API, nothing else',
      maxSessionDuration: Duration.hours(1),
      assumedBy: new iam.FederatedPrincipal(
        'cognito-identity.amazonaws.com',
        {
          StringEquals: { 'cognito-identity.amazonaws.com:aud': this.identityPool.ref },
          'ForAnyValue:StringLike': { 'cognito-identity.amazonaws.com:amr': 'authenticated' },
        },
        'sts:AssumeRoleWithWebIdentity',
      ),
    });
    appUserRole.addToPolicy(
      new iam.PolicyStatement({
        actions: ['execute-api:Invoke'],
        // The three routes on the one stage, and nothing else on the API.
        resources: ROUTES.map((path) => stack.formatArn({ service: 'execute-api', resource: this.api.apiId, resourceName: `$default/POST${path}` })),
      }),
    );
    new cognito.CfnIdentityPoolRoleAttachment(this, 'IdentityPoolRoles', {
      identityPoolId: this.identityPool.ref,
      roles: { authenticated: appUserRole.roleArn },
    });
  }
}

/** A contact flow's id from its ARN (arn:…:instance/<instance>/contact-flow/<id>). */
function flowId(flow: { attrContactFlowArn: string }): string {
  return Fn.select(3, Fn.split('/', flow.attrContactFlowArn));
}
