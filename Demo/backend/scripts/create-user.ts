// npm run create-user [username]
// Creates a demo user in the user pool (or resets the password of an existing one). The password is
// typed without echo and never stored.
import {
  AdminCreateUserCommand,
  AdminGetUserCommand,
  AdminSetUserPasswordCommand,
  CognitoIdentityProviderClient,
} from '@aws-sdk/client-cognito-identity-provider';
import { fail, main, prompt, region, requireOutputs } from './lib';

main(async () => {
  const { UserPoolId } = await requireOutputs('base');
  const cognito = new CognitoIdentityProviderClient({ region: region() });
  const username = process.argv[2] || (await prompt('Demo username [jordan]: ')) || 'jordan';
  if (!/^[A-Za-z0-9._-]{3,64}$/.test(username)) fail('Usernames are 3-64 letters, digits, . _ or -.');

  const password = await prompt(`Password for ${username} (12+ characters, upper and lower case, a digit): `, true);
  if (password.length < 12 || !/[a-z]/.test(password) || !/[A-Z]/.test(password) || !/\d/.test(password)) {
    fail('The password needs 12+ characters with upper and lower case letters and a digit.');
  }
  if ((await prompt('Type it again: ', true)) !== password) fail('The passwords do not match.');

  let exists = true;
  try { await cognito.send(new AdminGetUserCommand({ UserPoolId, Username: username })); } catch { exists = false; }
  if (!exists) await cognito.send(new AdminCreateUserCommand({ UserPoolId, Username: username, MessageAction: 'SUPPRESS' }));
  await cognito.send(new AdminSetUserPasswordCommand({ UserPoolId, Username: username, Password: password, Permanent: true }));
  console.log(`✔ ${exists ? 'Reset the password of' : 'Created'} ${username}. Sign in to the demo app with it.`);
});
