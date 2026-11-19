// npm run app-config
// Prints the demo apps' live-mode settings from the stack outputs: the iOS LiveConfig.plist and the
// Android live.properties. None of the values is a secret.
import { main, requireOutputs } from './lib';

main(async () => {
  const o = await requireOutputs('agent');
  const connectUrl = process.env.CONNECT_INSTANCE_URL ?? '';
  const values: Array<[string, string, string]> = [
    // [iOS key, Android key, value]
    ['ACME_LIVE_ENDPOINT', 'endpoint', o.ApiEndpoint],
    ['ACME_LIVE_REGION', 'region', o.Region],
    ['ACME_COGNITO_USER_POOL_ID', 'userPoolId', o.UserPoolId],
    ['ACME_COGNITO_CLIENT_ID', 'clientId', o.UserPoolClientId],
    ['ACME_COGNITO_IDENTITY_POOL_ID', 'identityPoolId', o.IdentityPoolId],
    ['ACME_CONNECT_INSTANCE_URL', 'connectInstanceUrl', connectUrl],
  ];

  console.log('# iOS — save as Demo/AcmeBank/Resources/LiveConfig.plist (gitignored), then build and run');
  console.log('<?xml version="1.0" encoding="UTF-8"?>');
  console.log('<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">');
  console.log('<plist version="1.0">\n<dict>');
  for (const [key, , value] of values) console.log(`  <key>${key}</key>\n  <string>${value}</string>`);
  console.log('</dict>\n</plist>\n');

  console.log('# Android — save as demo/acme-bank/live.properties (gitignored), then build and run');
  for (const [, key, value] of values) console.log(`${key}=${value}`);

  if (!connectUrl) console.log('\n# Tip: set CONNECT_INSTANCE_URL in .env (https://<alias>.my.connect.aws) to fill connectInstanceUrl.');
});
